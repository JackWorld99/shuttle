#![cfg(feature = "http")]

//! Shuttle's resume extension: an upload that loses its connection keeps what
//! arrived, and the same sender (by its client certificate) continues it at
//! that offset. The checksum of the whole file proves the parts belong together.

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::crypto::hash::sha256_hex;
use localsend::http::client::{
    ClientError, LsHttpClient, LsHttpClientV2, LsHttpClientVersion, UploadOptions,
};
use localsend::http::dto::PrepareUploadRequestDto;
use localsend::http::dto_v2::{
    PrepareUploadRequestDtoV2, PrepareUploadResponseDtoV2, RegisterDtoV2, ShuttleResumeRequest,
};
use localsend::http::server::common::save::FileUploadTarget;
use localsend::http::server::v2::{PrepareUploadDecisionV2, ServerEventV2, SessionEndReasonV2};
use localsend::http::server::web::WebConfig;
use localsend::http::server::{start_with_port, ServerConfigV2, TlsConfig};
use localsend::http::state::ClientInfo;
use localsend::model::discovery::ProtocolType;
use localsend::model::transfer::{FileContent, FileDto};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, Mutex, Notify};
use tokio_util::sync::CancellationToken;

struct Identity {
    cert: String,
    private_key: String,
    fingerprint: String,
}

fn generate_identity() -> Identity {
    let cert = localsend::crypto::cert::generate_self_signed().unwrap();
    Identity {
        cert: cert.certificate_pem,
        private_key: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    }
}

/// A partial file the test application keeps for a sender and a file.
#[derive(Clone, Debug)]
struct Partial {
    path: PathBuf,
    /// The offset the upload can be continued at (as reported on `saved_tx`).
    saved: u64,
}

/// What the test application saw, for the assertions.
#[derive(Default)]
struct AppState {
    /// Partial files by (sender certificate, file SHA-256), like Shuttle's
    /// resume index. Without a certificate there is no entry.
    partials: HashMap<(String, String), Partial>,
    /// Completely received files by file ID.
    completed: HashMap<String, Vec<u8>>,
    /// Upload results in order: (file ID, offset, result).
    results: Vec<(String, u64, Result<(), String>)>,
    /// prepare-upload requests in order: (resume request, offsets answered).
    prepares: Vec<(Option<ShuttleResumeRequest>, HashMap<String, u64>)>,
    session_ends: Vec<(String, SessionEndReasonV2)>,
    /// The certificate of each session's sender.
    session_certs: HashMap<String, Option<String>>,
    /// Uploads whose result has not been reported yet.
    in_flight: usize,
}

struct TestServer {
    port: u16,
    state: Arc<Mutex<AppState>>,
    dir: PathBuf,
    _stop_tx: oneshot::Sender<()>,
}

impl Drop for TestServer {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

impl TestServer {
    /// Waits until `condition` holds for the application state.
    async fn wait_until(&self, what: &str, condition: impl Fn(&AppState) -> bool) {
        for _ in 0..250 {
            if condition(&*self.state.lock().await) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        panic!("timed out waiting until {what}");
    }

    async fn partial(&self, sender: &Identity, sha256: &str) -> Option<Partial> {
        self.state
            .lock()
            .await
            .partials
            .get(&(sender.fingerprint.clone(), sha256.to_string()))
            .cloned()
    }
}

/// Starts a server whose application keeps partial files like Shuttle does:
/// it continues a file at the offset saved for the same sender certificate and
/// file checksum.
async fn start_server(identity: Option<&Identity>, verify_checksums: bool) -> TestServer {
    let _ = tracing_subscriber::fmt().with_test_writer().try_init();
    let dir = std::env::temp_dir().join(format!("localsend-resume-test-{}", uuid::Uuid::new_v4()));
    tokio::fs::create_dir_all(&dir).await.unwrap();

    let state: Arc<Mutex<AppState>> = Arc::new(Mutex::new(AppState::default()));
    let uploads_done = Arc::new(Notify::new());
    let (event_tx, mut event_rx) = mpsc::channel::<ServerEventV2>(16);

    tokio::spawn({
        let state = state.clone();
        let dir = dir.clone();
        async move {
            while let Some(event) = event_rx.recv().await {
                match event {
                    ServerEventV2::PrepareUpload {
                        session_id,
                        cert_fingerprint,
                        files,
                        resume,
                        decision_tx,
                        ..
                    } => {
                        // Like Shuttle: the offsets of a continuation are only
                        // known once the replaced session's uploads are over.
                        if resume.as_ref().is_some_and(|r| r.resume_of.is_some()) {
                            loop {
                                let notified = uploads_done.notified();
                                if state.lock().await.in_flight == 0 {
                                    break;
                                }
                                notified.await;
                            }
                        }

                        let mut state = state.lock().await;
                        state
                            .session_certs
                            .insert(session_id, cert_fingerprint.clone());
                        let ids = files.keys().cloned().collect();
                        let decision = match (&resume, &cert_fingerprint) {
                            (Some(_), Some(cert)) => {
                                let offsets: HashMap<String, u64> = files
                                    .iter()
                                    .filter_map(|(id, file)| {
                                        let sha256 = file.sha256.clone()?;
                                        let saved = state
                                            .partials
                                            .get(&(cert.clone(), sha256))
                                            .map_or(0, |partial| partial.saved);
                                        Some((id.clone(), saved))
                                    })
                                    .collect();
                                state.prepares.push((resume.clone(), offsets.clone()));
                                PrepareUploadDecisionV2::AcceptWithOffsets(ids, offsets)
                            }
                            _ => {
                                state.prepares.push((resume.clone(), HashMap::new()));
                                PrepareUploadDecisionV2::Accept(ids)
                            }
                        };
                        let _ = decision_tx.send(decision);
                    }
                    ServerEventV2::FileUpload {
                        session_id,
                        file_id,
                        file,
                        offset,
                        resumable,
                        target_tx,
                    } => {
                        let mut guard = state.lock().await;
                        let cert = guard.session_certs.get(&session_id).cloned().flatten();
                        let key = match (resumable, cert, file.sha256.clone()) {
                            (true, Some(cert), Some(sha256)) => Some((cert, sha256)),
                            _ => None,
                        };
                        let existing = key
                            .as_ref()
                            .and_then(|key| guard.partials.get(key).cloned());
                        let path = match (offset, existing) {
                            (0, _) | (_, None) => {
                                dir.join(format!("{}.part", uuid::Uuid::new_v4()))
                            }
                            (_, Some(partial)) => partial.path,
                        };
                        if let Some(key) = &key {
                            guard.partials.insert(
                                key.clone(),
                                Partial {
                                    path: path.clone(),
                                    saved: offset,
                                },
                            );
                        }
                        guard.in_flight += 1;
                        drop(guard);

                        let (result_tx, result_rx) = oneshot::channel();
                        let (saved_tx, mut saved_rx) = mpsc::unbounded_channel();
                        let _ = target_tx.send(FileUploadTarget::Path {
                            path: path.clone(),
                            result_tx,
                            progress_tx: None,
                            saved_tx: resumable.then_some(saved_tx),
                        });

                        let state = state.clone();
                        let uploads_done = uploads_done.clone();
                        tokio::spawn(async move {
                            let result = result_rx
                                .await
                                .unwrap_or_else(|_| Err("Upload aborted".to_string()));
                            let mut state = state.lock().await;
                            // The writer reports what it saved before the result.
                            while let Ok(saved) = saved_rx.try_recv() {
                                if let Some(partial) =
                                    key.as_ref().and_then(|key| state.partials.get_mut(key))
                                {
                                    partial.saved = saved;
                                }
                            }
                            if result.is_ok() {
                                let content = tokio::fs::read(&path).await.unwrap();
                                state.completed.insert(file_id.clone(), content);
                                if let Some(key) = &key {
                                    state.partials.remove(key);
                                }
                            }
                            state.results.push((file_id, offset, result));
                            state.in_flight -= 1;
                            uploads_done.notify_waiters();
                        });
                    }
                    ServerEventV2::SessionEnd { session_id, reason } => {
                        state.lock().await.session_ends.push((session_id, reason));
                    }
                    _ => {}
                }
            }
        }
    });

    let (stop_tx, stop_rx) = oneshot::channel::<()>();
    let handle = start_with_port(
        0,
        identity.map(|identity| TlsConfig {
            cert: identity.cert.clone(),
            private_key: identity.private_key.clone(),
        }),
        ClientInfo {
            alias: "Resume Test Server".to_string(),
            version: "2.2".to_string(),
            device_model: None,
            device_type: None,
            token: identity.map_or("server".to_string(), |i| i.fingerprint.clone()),
        },
        None,
        Some(ServerConfigV2 {
            pin: None,
            verify_checksums,
            event_tx,
        }),
        WebConfig::default(),
        stop_rx,
    )
    .await
    .expect("Failed to start server");

    TestServer {
        port: handle.port(),
        state,
        dir,
        _stop_tx: stop_tx,
    }
}

fn client(sender: &Identity, server: &Identity) -> LsHttpClientV2 {
    LsHttpClientV2::try_new(
        &sender.private_key,
        &sender.cert,
        Some(server.fingerprint.clone()),
        None,
    )
    .unwrap()
}

fn sender_info(fingerprint: &str) -> RegisterDtoV2 {
    RegisterDtoV2 {
        alias: "Resume Sender".to_string(),
        version: "2.2".to_string(),
        device_model: None,
        device_type: None,
        fingerprint: fingerprint.to_string(),
        port: 53317,
        protocol: ProtocolType::Https,
        download: false,
    }
}

/// 1 MiB of content that is not the same at every offset.
fn content() -> Vec<u8> {
    (0..1024 * 1024u32)
        .map(|i| (i % 251) as u8 ^ (i >> 12) as u8)
        .collect()
}

fn file_dto(id: &str, content: &[u8]) -> FileDto {
    FileDto {
        id: id.to_string(),
        file_name: format!("{id}.bin"),
        size: content.len() as u64,
        file_type: "application/octet-stream".to_string(),
        sha256: Some(sha256_hex(content)),
        preview: None,
        metadata: None,
    }
}

fn request(
    sender: &Identity,
    files: &[FileDto],
    resume: Option<ShuttleResumeRequest>,
) -> PrepareUploadRequestDtoV2 {
    PrepareUploadRequestDtoV2 {
        info: sender_info(&sender.fingerprint),
        files: files.iter().map(|f| (f.id.clone(), f.clone())).collect(),
        shuttle_resume: resume,
    }
}

fn resume(resume_of: Option<&str>) -> Option<ShuttleResumeRequest> {
    Some(ShuttleResumeRequest {
        v: 1,
        resume_of: resume_of.map(str::to_string),
    })
}

async fn prepare(
    client: &LsHttpClientV2,
    protocol: ProtocolType,
    port: u16,
    request: PrepareUploadRequestDtoV2,
) -> Result<PrepareUploadResponseDtoV2, ClientError> {
    let result = client
        .prepare_upload(
            protocol,
            "127.0.0.1",
            port,
            None,
            request,
            None,
            CancellationToken::new(),
        )
        .await?;
    Ok(result.response.expect("expected a session"))
}

/// How the body of [upload_part] ends after its content.
enum BodyEnd {
    /// The body is complete.
    Complete,
    /// The connection is cut: the body fails, which closes the connection.
    Cut,
    /// The connection stays open but nothing arrives anymore, like a network
    /// that went away silently.
    Stall,
}

/// Uploads `content` as the part of a file starting at `offset`, ending as `end`.
#[allow(clippy::too_many_arguments)]
async fn upload_part(
    client: &LsHttpClientV2,
    port: u16,
    session_id: &str,
    file_id: &str,
    token: &str,
    offset: Option<u64>,
    content: Vec<u8>,
    end: BodyEnd,
) -> Result<(), ClientError> {
    let chunks: Vec<Result<Bytes, std::io::Error>> = content
        .chunks(16 * 1024)
        .map(|chunk| Ok(Bytes::copy_from_slice(chunk)))
        .collect();
    let content = futures_util::stream::iter(chunks);
    let body = match end {
        BodyEnd::Complete => localsend::reqwest::Body::wrap_stream(content),
        BodyEnd::Cut => localsend::reqwest::Body::wrap_stream(content.chain(
            futures_util::stream::once(async {
                // Let the bytes before the cut reach the receiver.
                tokio::time::sleep(Duration::from_millis(300)).await;
                Err(std::io::Error::other("connection cut"))
            }),
        )),
        BodyEnd::Stall => {
            localsend::reqwest::Body::wrap_stream(content.chain(futures_util::stream::pending()))
        }
    };
    client
        .upload_from(
            ProtocolType::Https,
            "127.0.0.1",
            port,
            None,
            session_id,
            file_id,
            token,
            offset,
            body,
            CancellationToken::new(),
        )
        .await
}

fn status_of(result: &Result<(), ClientError>) -> Option<u16> {
    match result {
        Err(ClientError::StatusCode(e)) => Some(e.status),
        _ => None,
    }
}

const HALF: usize = 512 * 1024;

/// The body of an upload that is expected to be rejected before it is read.
/// A receiver that rejects early closes the connection; while the sender is
/// still writing a large body, it may only see the connection being aborted
/// instead of the status (the sender then continues in a new session, whose
/// offset is 0 by then). A body sent completely before the answer gets the status.
fn short(content: &[u8], from: usize) -> Vec<u8> {
    content[from..from + 1024].to_vec()
}

/// The main case: the connection is cut halfway through a file. The receiver
/// keeps what arrived; the sender continues at that offset in a new request,
/// reading the rest from the file; the result is the complete, verified file.
#[tokio::test]
async fn test_cut_connection_continues_at_saved_offset() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = client(&sender, &server_identity);
    let content = content();
    let file = file_dto("video", &content);

    // First attempt: the receiver offers to continue it later (offset 0).
    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    assert_eq!(
        response.shuttle_resume,
        Some(HashMap::from([("video".to_string(), 0)]))
    );

    let result = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content[..HALF].to_vec(),
        BodyEnd::Cut,
    )
    .await;
    assert!(result.is_err(), "the cut upload must fail");

    server
        .wait_until("the cut upload was reported", |s| s.results.len() == 1)
        .await;
    let partial = server
        .partial(&sender, file.sha256.as_deref().unwrap())
        .await
        .unwrap();
    assert!(
        partial.saved > 0 && partial.saved <= HALF as u64,
        "saved {}",
        partial.saved
    );
    assert_eq!(
        tokio::fs::metadata(&partial.path).await.unwrap().len(),
        partial.saved,
        "the received part stays on disk"
    );
    // The only file failed, so the session is over.
    server
        .wait_until("the session ended", |s| s.session_ends.len() == 1)
        .await;

    // The continuation: the receiver names the saved offset.
    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(
            &sender,
            std::slice::from_ref(&file),
            resume(Some(&response.session_id)),
        ),
    )
    .await
    .unwrap();
    assert_eq!(
        response.shuttle_resume,
        Some(HashMap::from([("video".to_string(), partial.saved)]))
    );

    // The rest is read from the file at the offset (the generic client, as the app uses it).
    let source = server.dir.join("source.bin");
    tokio::fs::write(&source, &content).await.unwrap();
    let app_client = LsHttpClient::new(
        &sender.private_key,
        &sender.cert,
        LsHttpClientVersion::V2,
        Some(server_identity.fingerprint.clone()),
        None,
    )
    .unwrap();
    let first_progress = Arc::new(AtomicU64::new(u64::MAX));
    let progress = first_progress.clone();
    app_client
        .upload(
            ProtocolType::Https,
            "127.0.0.1",
            server.port,
            None,
            &response.session_id,
            "video",
            &response.files["video"],
            FileContent::Path(source),
            content.len() as u64,
            UploadOptions {
                offset: Some(partial.saved),
                stall_timeout: Some(Duration::from_secs(30)),
            },
            move |sent| {
                let _ =
                    progress.compare_exchange(u64::MAX, sent, Ordering::Relaxed, Ordering::Relaxed);
            },
            CancellationToken::new(),
        )
        .await
        .expect("the continued upload must succeed");

    // Progress counts from the start of the file.
    assert!(first_progress.load(Ordering::Relaxed) > partial.saved);

    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    let state = server.state.lock().await;
    assert_eq!(state.completed["video"], content);
    assert_eq!(state.results.last().unwrap().1, partial.saved);
    assert!(state.partials.is_empty());
}

/// The receiver may not notice a lost connection for minutes. A continuation
/// from the same sender replaces the hanging session instead of getting
/// "busy", and the hanging upload stops and keeps what it received.
#[tokio::test]
async fn test_continuation_replaces_session_with_hanging_upload() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = Arc::new(client(&sender, &server_identity));
    let content = content();
    let file = file_dto("video", &content);

    let first = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();

    let hanging = tokio::spawn({
        let client = client.clone();
        let port = server.port;
        let first = first.clone();
        let part = content[..HALF].to_vec();
        async move {
            upload_part(
                &client,
                port,
                &first.session_id,
                "video",
                &first.files["video"],
                Some(0),
                part,
                BodyEnd::Stall,
            )
            .await
        }
    });
    // Let the first half arrive.
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(
        server.state.lock().await.results.is_empty(),
        "the upload must still hang"
    );

    // A plain new request from the same sender is still blocked by the session.
    let busy = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await;
    assert_eq!(status_of(&busy.map(|_| ())), Some(409));

    let second = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(
            &sender,
            std::slice::from_ref(&file),
            resume(Some(&first.session_id)),
        ),
    )
    .await
    .expect("the continuation must replace the hanging session");

    {
        let state = server.state.lock().await;
        assert_eq!(
            state.session_ends,
            vec![(first.session_id.clone(), SessionEndReasonV2::Replaced)]
        );
        assert!(
            state.results[0].2.is_err(),
            "the hanging upload was stopped"
        );
    }
    let saved = second.shuttle_resume.as_ref().unwrap()["video"];
    assert!(saved > 0 && saved <= HALF as u64, "saved {saved}");

    upload_part(
        &client,
        server.port,
        &second.session_id,
        "video",
        &second.files["video"],
        Some(saved),
        content[saved as usize..].to_vec(),
        BodyEnd::Complete,
    )
    .await
    .expect("the continued upload must succeed");

    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    assert_eq!(server.state.lock().await.completed["video"], content);
    hanging.abort();
}

/// Only the certificate that started a session can replace it, even when it
/// names the right session.
#[tokio::test]
async fn test_other_certificate_cannot_replace_session() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let intruder = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = Arc::new(client(&sender, &server_identity));
    let content = content();
    let file = file_dto("video", &content);

    let first = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let hanging = tokio::spawn({
        let client = client.clone();
        let port = server.port;
        let first = first.clone();
        let part = content[..HALF].to_vec();
        async move {
            upload_part(
                &client,
                port,
                &first.session_id,
                "video",
                &first.files["video"],
                Some(0),
                part,
                BodyEnd::Stall,
            )
            .await
        }
    });
    tokio::time::sleep(Duration::from_millis(500)).await;

    // The intruder even claims the sender's fingerprint in the body.
    let mut claim = request(
        &intruder,
        std::slice::from_ref(&file),
        resume(Some(&first.session_id)),
    );
    claim.info.fingerprint = sender.fingerprint.clone();
    let result = prepare(
        &self::client(&intruder, &server_identity),
        ProtocolType::Https,
        server.port,
        claim,
    )
    .await;
    assert_eq!(status_of(&result.map(|_| ())), Some(409));

    let state = server.state.lock().await;
    assert!(
        state.session_ends.is_empty(),
        "the session must not be replaced"
    );
    assert!(state.results.is_empty(), "the upload must keep running");
    drop(state);
    hanging.abort();
}

/// The partial file is bound to the sender's certificate: another device
/// offering the same file starts at 0.
#[tokio::test]
async fn test_partial_file_is_bound_to_the_sender_certificate() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let other = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = client(&sender, &server_identity);
    let content = content();
    let file = file_dto("video", &content);

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let _ = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content[..HALF].to_vec(),
        BodyEnd::Cut,
    )
    .await;
    server
        .wait_until("the cut upload was reported", |s| s.results.len() == 1)
        .await;
    assert!(
        server
            .partial(&sender, file.sha256.as_deref().unwrap())
            .await
            .unwrap()
            .saved
            > 0
    );

    let response = prepare(
        &self::client(&other, &server_identity),
        ProtocolType::Https,
        server.port,
        request(&other, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    assert_eq!(
        response.shuttle_resume,
        Some(HashMap::from([("video".to_string(), 0)]))
    );
}

/// Only the offset the receiver named (or 0) is accepted. A sender that does
/// not use the offset (an older one) uploads the whole file and that works.
#[tokio::test]
async fn test_wrong_offset_rejected_and_whole_file_still_accepted() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = client(&sender, &server_identity);
    let content = content();
    let file = file_dto("video", &content);

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let _ = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content[..HALF].to_vec(),
        BodyEnd::Cut,
    )
    .await;
    server
        .wait_until("the cut upload was reported", |s| s.results.len() == 1)
        .await;

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let saved = response.shuttle_resume.as_ref().unwrap()["video"];
    assert!(saved > 0);

    let wrong = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(saved + 1),
        short(&content, saved as usize + 1),
        BodyEnd::Complete,
    )
    .await;
    assert_eq!(status_of(&wrong), Some(409));

    // No offset at all: the whole file.
    upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        None,
        content.clone(),
        BodyEnd::Complete,
    )
    .await
    .expect("the whole file must be accepted");
    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    assert_eq!(server.state.lock().await.completed["video"], content);
}

/// A kept part that was changed on disk is caught by the checksum of the whole
/// file, even with checksum verification turned off on the receiver: nothing
/// of it is kept, and the whole file is uploaded again.
#[tokio::test]
async fn test_corrupted_partial_file_caught_by_checksum() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), false).await;
    let client = client(&sender, &server_identity);
    let content = content();
    let file = file_dto("video", &content);

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let _ = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content[..HALF].to_vec(),
        BodyEnd::Cut,
    )
    .await;
    server
        .wait_until("the cut upload was reported", |s| s.results.len() == 1)
        .await;
    let partial = server
        .partial(&sender, file.sha256.as_deref().unwrap())
        .await
        .unwrap();

    // Flip a byte in the kept part.
    let mut kept = tokio::fs::read(&partial.path).await.unwrap();
    kept[100] ^= 0xff;
    tokio::fs::write(&partial.path, &kept).await.unwrap();

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let saved = response.shuttle_resume.as_ref().unwrap()["video"];
    let result = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(saved),
        content[saved as usize..].to_vec(),
        BodyEnd::Complete,
    )
    .await;
    assert_eq!(status_of(&result), Some(422));
    server
        .wait_until("the mismatch was reported", |s| s.results.len() == 2)
        .await;
    assert_eq!(
        server
            .partial(&sender, file.sha256.as_deref().unwrap())
            .await
            .unwrap()
            .saved,
        0,
        "nothing of the corrupted file may be continued"
    );

    // The retry uploads the whole file.
    upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content.clone(),
        BodyEnd::Complete,
    )
    .await
    .expect("the whole file must be accepted after a mismatch");
    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    assert_eq!(server.state.lock().await.completed["video"], content);
}

/// The partial file disappeared (e.g. deleted by the user): the receiver
/// answers 409 and the sender uploads the whole file.
#[tokio::test]
async fn test_missing_partial_file_gives_offset_mismatch() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = client(&sender, &server_identity);
    let content = content();
    let file = file_dto("video", &content);

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let _ = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content[..HALF].to_vec(),
        BodyEnd::Cut,
    )
    .await;
    server
        .wait_until("the cut upload was reported", |s| s.results.len() == 1)
        .await;
    let partial = server
        .partial(&sender, file.sha256.as_deref().unwrap())
        .await
        .unwrap();
    tokio::fs::remove_file(&partial.path).await.unwrap();

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    let saved = response.shuttle_resume.as_ref().unwrap()["video"];
    let result = upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(saved),
        short(&content, saved as usize),
        BodyEnd::Complete,
    )
    .await;
    assert_eq!(status_of(&result), Some(409));

    upload_part(
        &client,
        server.port,
        &response.session_id,
        "video",
        &response.files["video"],
        Some(0),
        content.clone(),
        BodyEnd::Complete,
    )
    .await
    .expect("the whole file must be accepted");
    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    assert_eq!(server.state.lock().await.completed["video"], content);
}

/// Without a client certificate (no encryption) there is no identity to bind
/// a partial file to: the extension is not offered at all.
#[tokio::test]
async fn test_no_resume_without_client_certificate() {
    let server = start_server(None, true).await;
    let client = LsHttpClientV2::try_new_without_cert().unwrap();
    let sender = generate_identity();
    let content = content();
    let file = file_dto("video", &content);

    let response = prepare(
        &client,
        ProtocolType::Http,
        server.port,
        request(&sender, std::slice::from_ref(&file), resume(None)),
    )
    .await
    .unwrap();
    assert_eq!(response.shuttle_resume, None);
    assert_eq!(
        server.state.lock().await.prepares,
        vec![(None, HashMap::new())]
    );

    // An offset is refused, the whole file works as always.
    let token = &response.files["video"];
    let url = |offset: &str| {
        format!(
            "http://127.0.0.1:{}/api/localsend/v2/upload?sessionId={}&fileId=video&token={token}{offset}",
            server.port, response.session_id
        )
    };
    let http = localsend::reqwest::Client::new();
    let refused = http
        .post(url("&offset=1000"))
        .body(short(&content, 1000))
        .send()
        .await
        .unwrap();
    assert_eq!(refused.status().as_u16(), 409);
    let accepted = http
        .post(url(""))
        .body(content.clone())
        .send()
        .await
        .unwrap();
    assert_eq!(accepted.status().as_u16(), 200);
    server
        .wait_until("the file was completed", |s| {
            s.completed.contains_key("video")
        })
        .await;
    assert_eq!(server.state.lock().await.completed["video"], content);
}

/// A file without a checksum cannot be continued: nothing could prove that
/// the parts belong together.
#[tokio::test]
async fn test_file_without_checksum_is_not_continuable() {
    let server_identity = generate_identity();
    let sender = generate_identity();
    let server = start_server(Some(&server_identity), true).await;
    let client = client(&sender, &server_identity);
    let mut file = file_dto("video", &content());
    file.sha256 = None;

    let response = prepare(
        &client,
        ProtocolType::Https,
        server.port,
        request(&sender, &[file], resume(None)),
    )
    .await
    .unwrap();
    assert_eq!(response.shuttle_resume, Some(HashMap::new()));
}

/// The generic request DTO carries the extension to the v2 wire format.
#[test]
fn test_generic_request_carries_resume() {
    let sender = generate_identity();
    let request = PrepareUploadRequestDto {
        info: localsend::http::dto::RegisterDto {
            alias: "A".to_string(),
            version: "2.2".to_string(),
            device_model: None,
            device_type: None,
            token: sender.fingerprint,
            port: 1,
            protocol: ProtocolType::Https,
            has_web_interface: false,
        },
        files: HashMap::new(),
        shuttle_resume: resume(Some("s")),
    };
    let v2: PrepareUploadRequestDtoV2 = request.into();
    assert_eq!(v2.shuttle_resume, resume(Some("s")));
}
