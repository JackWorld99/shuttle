//! Shuttle: real-device check of continuing interrupted uploads (resume).
//!
//! Sends one file to a receiver over HTTPS with a client certificate that is
//! kept in `identity.json`, so later runs are the same sender. With `--cut`,
//! the connection is cut after that many bytes, like a lost Wi-Fi. With
//! `--continue-after`, the same run then continues in a new session that names
//! the interrupted one (as Shuttle does after a lost connection); otherwise a
//! later run without `--cut` continues it (as "Continue sending" does).
//!
//! Usage:
//!   cargo run --release --example resume_send --features full -- \
//!     <host> <port> <file> <identity.json> [--cut <bytes>] [--continue-after <seconds>]

use bytes::Bytes;
use futures_util::StreamExt;
use localsend::crypto::hash::sha256_file_content;
use localsend::http::client::{LsHttpClient, LsHttpClientV2, LsHttpClientVersion, UploadOptions};
use localsend::http::dto::{PrepareUploadRequestDto, RegisterDto, ShuttleResumeRequest};
use localsend::model::discovery::{DeviceType, ProtocolType, PROTOCOL_VERSION_V2};
use localsend::model::transfer::{FileContent, FileDto};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::io::AsyncReadExt;
use tokio_util::sync::CancellationToken;

#[derive(serde::Serialize, serde::Deserialize)]
struct Identity {
    certificate_pem: String,
    private_key_pem: String,
    fingerprint: String,
}

fn load_identity(path: &PathBuf) -> anyhow::Result<Identity> {
    if let Ok(json) = std::fs::read_to_string(path) {
        return Ok(serde_json::from_str(&json)?);
    }
    let cert = localsend::crypto::cert::generate_self_signed()?;
    let identity = Identity {
        certificate_pem: cert.certificate_pem,
        private_key_pem: cert.private_key_pem,
        fingerprint: cert.fingerprint,
    };
    std::fs::write(path, serde_json::to_string(&identity)?)?;
    Ok(identity)
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let usage = "<host> <port> <file> <identity.json> [--cut <bytes>] [--continue-after <seconds>]";
    let [host, port, file, identity_path, rest @ ..] = args.as_slice() else {
        anyhow::bail!("usage: {usage}");
    };
    let port: u16 = port.parse()?;
    let file = PathBuf::from(file);
    let mut cut: Option<u64> = None;
    let mut continue_after: Option<u64> = None;
    let mut rest = rest.iter();
    while let Some(flag) = rest.next() {
        let value = rest
            .next()
            .ok_or_else(|| anyhow::anyhow!("usage: {usage}"))?;
        match flag.as_str() {
            "--cut" => cut = Some(value.parse()?),
            "--continue-after" => continue_after = Some(value.parse()?),
            _ => anyhow::bail!("usage: {usage}"),
        }
    }

    let identity = load_identity(&PathBuf::from(identity_path))?;
    let size = tokio::fs::metadata(&file).await?.len();
    println!("Hashing {} ({size} bytes)...", file.display());
    let sha256 = sha256_file_content(
        FileContent::Path(file.clone()),
        &CancellationToken::new(),
        |_| {},
    )
    .await
    .map_err(|e| anyhow::anyhow!("{e:?}"))?;
    println!("SHA-256 {sha256}");

    let file_dto = FileDto {
        id: "resume-file".to_string(),
        file_name: file.file_name().unwrap().to_string_lossy().to_string(),
        size,
        file_type: if file.extension().is_some_and(|e| e == "mp4") {
            "video/mp4".to_string()
        } else {
            "application/octet-stream".to_string()
        },
        sha256: Some(sha256),
        preview: None,
        metadata: None,
    };
    let request = |resume_of: Option<String>| PrepareUploadRequestDto {
        info: RegisterDto {
            alias: "Resume Check".to_string(),
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: Some("resume_send".to_string()),
            device_type: Some(DeviceType::Headless),
            token: identity.fingerprint.clone(),
            port: 53399,
            protocol: ProtocolType::Https,
            has_web_interface: false,
        },
        files: HashMap::from([(file_dto.id.clone(), file_dto.clone())]),
        shuttle_resume: Some(ShuttleResumeRequest { v: 1, resume_of }),
    };

    let client = LsHttpClient::new(
        &identity.private_key_pem,
        &identity.certificate_pem,
        LsHttpClientVersion::V2,
        None,
        None,
    )?;
    let raw = LsHttpClientV2::try_new(
        &identity.private_key_pem,
        &identity.certificate_pem,
        None,
        None,
    )?;

    // prepare-upload; the receiver may ask its user first
    println!("Asking {host}:{port} to receive it (accept it there if asked)...");
    let prepared = client
        .prepare_upload(
            ProtocolType::Https,
            host,
            port,
            None,
            request(None),
            None,
            CancellationToken::new(),
        )
        .await?;
    let response = prepared
        .response
        .ok_or_else(|| anyhow::anyhow!("nothing accepted ({})", prepared.status_code))?;
    let token = response.files[&file_dto.id].clone();
    let offset = response
        .shuttle_resume
        .as_ref()
        .and_then(|offsets| offsets.get(&file_dto.id).copied());
    println!(
        "Session {}: the receiver starts at {offset:?}",
        response.session_id
    );
    let Some(offset) = offset else {
        anyhow::bail!("the receiver does not continue uploads");
    };

    let Some(cut) = cut else {
        upload_rest(
            &client,
            host,
            port,
            &response.session_id,
            &file_dto,
            &token,
            &file,
            offset,
        )
        .await?;
        return Ok(());
    };

    // Send up to `cut` bytes, then fail the body: the connection goes down mid-file.
    println!("Sending from {offset} and cutting the connection at {cut}...");
    let mut source = tokio::fs::File::open(&file).await?;
    let mut part = vec![0_u8; (cut - offset) as usize];
    tokio::io::AsyncSeekExt::seek(&mut source, std::io::SeekFrom::Start(offset)).await?;
    source.read_exact(&mut part).await?;
    let chunks: Vec<Result<Bytes, std::io::Error>> = part
        .chunks(256 * 1024)
        .map(|c| Ok(Bytes::copy_from_slice(c)))
        .collect();
    let body = localsend::reqwest::Body::wrap_stream(futures_util::stream::iter(chunks).chain(
        futures_util::stream::once(async {
            tokio::time::sleep(Duration::from_secs(1)).await;
            Err(std::io::Error::other("connection cut by resume_send"))
        }),
    ));
    let cut_result = raw
        .upload_from(
            ProtocolType::Https,
            host,
            port,
            None,
            &response.session_id,
            &file_dto.id,
            &token,
            Some(offset),
            body,
            CancellationToken::new(),
        )
        .await;
    println!("Cut upload ended: {cut_result:?}");

    let Some(seconds) = continue_after else {
        println!("Run again without --cut to continue it.");
        return Ok(());
    };
    tokio::time::sleep(Duration::from_secs(seconds)).await;

    println!("Continuing session {} in a new one...", response.session_id);
    let prepared = client
        .prepare_upload(
            ProtocolType::Https,
            host,
            port,
            None,
            request(Some(response.session_id.clone())),
            None,
            CancellationToken::new(),
        )
        .await?;
    let continued = prepared
        .response
        .ok_or_else(|| anyhow::anyhow!("nothing accepted ({})", prepared.status_code))?;
    let offset = continued
        .shuttle_resume
        .as_ref()
        .and_then(|offsets| offsets.get(&file_dto.id).copied())
        .unwrap_or(0);
    println!(
        "Session {}: the receiver continues at {offset}",
        continued.session_id
    );
    upload_rest(
        &client,
        host,
        port,
        &continued.session_id,
        &file_dto,
        &continued.files[&file_dto.id],
        &file,
        offset,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn upload_rest(
    client: &LsHttpClient,
    host: &str,
    port: u16,
    session_id: &str,
    file: &FileDto,
    token: &str,
    path: &Path,
    offset: u64,
) -> anyhow::Result<()> {
    let mut offset = offset;
    loop {
        println!("Sending the rest from {offset}...");
        let started = std::time::Instant::now();
        let result = client
            .upload(
                ProtocolType::Https,
                host,
                port,
                None,
                session_id,
                &file.id,
                token,
                FileContent::Path(path.to_path_buf()),
                file.size,
                UploadOptions {
                    offset: Some(offset),
                    stall_timeout: Some(Duration::from_secs(30)),
                },
                |_| {},
                CancellationToken::new(),
            )
            .await;
        match result {
            Ok(()) => {
                println!(
                    "Done: {} bytes sent in {:.1?}, the receiver verified the whole file",
                    file.size - offset,
                    started.elapsed()
                );
                return Ok(());
            }
            // Like Shuttle's upload isolate: after a checksum mismatch, or an
            // offset the receiver cannot continue at, the whole file again.
            Err(localsend::http::client::ClientError::StatusCode(e))
                if offset > 0 && (e.status == 422 || e.status == 409) =>
            {
                println!(
                    "The receiver answered {} ({:?}), sending the whole file",
                    e.status, e.message
                );
                offset = 0;
            }
            Err(e) => return Err(e.into()),
        }
    }
}
