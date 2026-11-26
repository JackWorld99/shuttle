use crate::http::dto_v2::{
    InfoResponseDtoV2, PrepareUploadRequestDtoV2, PrepareUploadResponseDtoV2, RegisterDtoV2,
    RegisterResponseDtoV2, ShuttleResumeRequest,
};
use crate::http::server::common::collect_to_json::CollectToJson;
use crate::http::server::common::error::AppError;
use crate::http::server::common::pin::check_pin;
use crate::http::server::common::query::parse_query;
use crate::http::server::common::response::{empty_body, BoxedBody, JsonResponse};
use crate::http::server::common::save::{
    FileTimestamps, FileUploadTarget, SaveResult, UploadParams,
};
use crate::http::server::common::session::{
    FileStatusV2, PendingSessionV2, SessionFileV2, SessionStateV2, UploadSessionV2,
};
use crate::http::server::PeerIp;
use crate::http::server::{common, AppState, RequestClientInfo, V2State};
use crate::model::discovery::PROTOCOL_VERSION_V2;
use crate::model::transfer::FileDto;
use crate::util::filename;
use hyper::body::Incoming;
use hyper::{Request, Response, StatusCode};
use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

/// Events emitted by the v2 HTTP server that must be handled by the application.
#[derive(Debug)]
pub enum ServerEventV2 {
    /// A device registered itself via `POST /api/localsend/v2/register`.
    ///
    /// On TLS, this event is only emitted when `info.fingerprint` matches the
    /// SHA-256 fingerprint of the client certificate verified during the mTLS
    /// handshake, so the fingerprint cannot be spoofed.
    Register {
        /// The IP address of the remote device.
        ip: PeerIp,

        /// The device information sent by the remote device.
        info: RegisterDtoV2,
    },

    /// A sender requests to upload files via `POST /api/localsend/v2/prepare-upload`.
    ///
    /// The application must answer on `decision_tx`.
    /// Dropping `decision_tx` results in a 500 response.
    PrepareUpload {
        /// The session ID the upload session will have when the request is
        /// accepted. Pre-generated so the application can track the session
        /// consistently from the start.
        session_id: String,

        /// The IP address of the sender.
        ip: PeerIp,

        /// The device information of the sender.
        info: RegisterDtoV2,

        /// The SHA-256 fingerprint (uppercase hex) of the sender's client
        /// certificate verified during the mTLS handshake. Unlike
        /// `info.fingerprint`, this value cannot be spoofed.
        /// `None` when the server runs without TLS.
        cert_fingerprint: Option<String>,

        /// The offered files, mapped by file ID.
        files: HashMap<String, FileDto>,

        /// Shuttle's resume extension, if the sender asked for it. Only passed
        /// on together with `cert_fingerprint`: continuing an upload is bound
        /// to the sender's certificate. Answer with
        /// [PrepareUploadDecisionV2::AcceptWithOffsets] to let files continue.
        ///
        /// When `resume_of` names the session that was active until now, that
        /// session was replaced by this request (its
        /// [ServerEventV2::SessionEnd] with [SessionEndReasonV2::Replaced]
        /// came first).
        resume: Option<ShuttleResumeRequest>,

        /// Channel to send the decision (accept all, a subset, or decline).
        decision_tx: oneshot::Sender<PrepareUploadDecisionV2>,
    },

    /// An accepted file is being uploaded via `POST /api/localsend/v2/upload`.
    ///
    /// The application must answer on `target_tx` with where the file content
    /// should go (a stream to consume itself, a path, or a file descriptor).
    /// Dropping `target_tx` results in a 500 response.
    FileUpload {
        /// The session ID of the upload session.
        session_id: String,

        /// The ID of the file being uploaded.
        file_id: String,

        /// The metadata of the file being uploaded.
        file: FileDto,

        /// Shuttle: the number of bytes of the file the target must already
        /// hold, from an earlier interrupted upload: this upload continues at
        /// that offset. 0 for an upload of the whole file.
        offset: u64,

        /// Shuttle: whether the upload can be continued later if it is
        /// interrupted. The application should then keep the received part
        /// (reported on `saved_tx` of the target) instead of discarding it.
        resumable: bool,

        /// Channel to send the target the file content should be written to.
        target_tx: oneshot::Sender<FileUploadTarget>,
    },

    /// An upload session ended.
    SessionEnd {
        /// The session ID of the ended session.
        session_id: String,

        /// Why the session ended.
        reason: SessionEndReasonV2,
    },

    /// A prepare-upload request was aborted before a session was created,
    /// e.g. the sender disconnected while the application was still deciding.
    /// The `decision_tx` of the [ServerEventV2::PrepareUpload] with the same
    /// session ID is dead; answering it has no effect.
    PrepareUploadAborted {
        /// The session ID of the aborted prepare-upload request.
        session_id: String,
    },

    /// `POST /api/localsend/v2/cancel` was received for a session this server
    /// does not manage. This happens when the remote device cancels a transfer
    /// that this application is currently *sending* to it: the session ID is
    /// the one issued by the remote device during prepare-upload.
    ///
    /// The application must verify that `ip` matches the target of the
    /// send session before cancelling it.
    CancelReceived {
        /// The IP address of the remote device requesting the cancellation.
        ip: PeerIp,

        /// The session ID as known by the remote device.
        session_id: String,
    },

    /// The listening socket failed permanently, e.g. because the OS
    /// invalidated it while the application was suspended (iOS reclaims the
    /// sockets of suspended apps). The server has stopped itself; the
    /// application must restart it to become reachable again.
    ListenerFailed {
        /// Description of the failure.
        error: String,
    },
}

/// The application's decision for a prepare-upload request.
#[derive(Debug)]
pub enum PrepareUploadDecisionV2 {
    /// Accept the given file IDs (a subset of the offered files).
    /// An empty set responds with 204 (no file transfer needed).
    Accept(HashSet<String>),

    /// Shuttle: like [PrepareUploadDecisionV2::Accept], and the files in the map
    /// can be continued if their upload is interrupted. The value is the
    /// offset their upload starts at: the number of bytes the application
    /// already holds from an earlier interrupted upload of the same file by the
    /// same sender, or 0.
    ///
    /// Offsets are ignored unless the request asked for the resume extension
    /// and the file has a checksum (which is then always verified), and when
    /// they exceed the file size.
    AcceptWithOffsets(HashSet<String>, HashMap<String, u64>),

    /// Decline the request (403).
    Decline,
}

/// Why an upload session ended.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum SessionEndReasonV2 {
    /// All accepted files reached a final state (finished or failed).
    Finished,

    /// The sender cancelled the session via `POST /api/localsend/v2/cancel`.
    Cancelled,

    /// Shuttle: the sender lost its connection and continues the session in a
    /// new one. The [ServerEventV2::PrepareUpload] of the new session follows,
    /// naming this session in `resume.resume_of`.
    Replaced,
}

pub(crate) async fn register(
    body: Incoming,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<JsonResponse<RegisterResponseDtoV2>, AppError> {
    let payload = body.collect_to_json::<RegisterDtoV2>().await?;

    // On TLS, only trust registrations whose claimed fingerprint is proven
    // by the client certificate of the mTLS handshake.
    let fingerprint_valid = match client_info.cert_fingerprint() {
        Some(cert_fingerprint) => payload.fingerprint.to_ascii_uppercase() == cert_fingerprint,
        None => true,
    };

    if let Some(v2) = &state.v2 {
        if fingerprint_valid {
            // Not awaited: registrations arrive in bursts (every device on the
            // network answers an announcement, and a peer scanning its subnet
            // registers with everyone), so the channel fills up easily. Waiting
            // would block this request handler — and every later one — until
            // the application catches up, which is what makes the device stop
            // answering `register` altogether.
            //
            // The event carries no responder, and peers repeat their
            // announcement, so a dropped registration is recoverable.
            if let Err(err) = v2.event_tx.try_send(ServerEventV2::Register {
                ip: client_info.ip,
                info: payload,
            }) {
                tracing::debug!("Dropped a register event: {err}");
            }
        } else {
            tracing::warn!(
                "Ignoring register from {}: claimed fingerprint does not match the client certificate",
                client_info.ip
            );
        }
    }

    let info = state.info.lock().await.clone();
    let download = state.web.share.download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: RegisterResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

pub(crate) async fn info(state: AppState) -> Result<JsonResponse<InfoResponseDtoV2>, AppError> {
    let info = state.info.lock().await.clone();
    let download = state.web.share.download().is_some();

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: InfoResponseDtoV2 {
            alias: info.alias,
            version: PROTOCOL_VERSION_V2.to_string(),
            device_model: info.device_model,
            device_type: info.device_type,
            fingerprint: info.token,
            download,
        },
    })
}

pub(crate) async fn prepare_upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    check_pin(
        v2.pin.as_deref(),
        &v2.pin_attempts,
        &query,
        client_info.ip.ip,
    )
    .await?;

    let mut payload = req
        .into_body()
        .collect_to_json::<PrepareUploadRequestDtoV2>()
        .await?;

    if payload.files.is_empty() {
        return Err(AppError::BadRequest("No files provided".to_string()));
    }

    // Shuttle: continuing uploads is bound to the sender's certificate; without
    // one there is no identity to bind it to.
    let cert_fingerprint = client_info.cert_fingerprint();
    let resume = match cert_fingerprint {
        Some(_) => payload.shuttle_resume.take(),
        None => None,
    };

    // Senders on macOS send NFD names (e.g. Korean as separate jamo). Normalize
    // once here so every consumer (UI, history, save path) sees NFC.
    for file in payload.files.values_mut() {
        file.file_name = filename::normalize(&file.file_name);
    }

    let session_id = Uuid::new_v4().to_string();
    let cancelled = CancellationToken::new();

    // Claim the single session slot.
    let replaced = {
        let mut slot = v2.session.lock().await;
        let replaced = match slot.as_ref() {
            None => None,
            // Shuttle: the sender continues its own session after losing the
            // connection, which this server may not have noticed yet. The old
            // session gives way; its uploads stop and keep what they received.
            Some(SessionStateV2::Active(active))
                if is_continuation_of(active, resume.as_ref(), cert_fingerprint.as_deref()) =>
            {
                active.abort.cancel();
                Some(active.session_id.clone())
            }
            Some(_) => {
                return Err(AppError::Message(
                    StatusCode::CONFLICT,
                    "Blocked by another session".to_string(),
                ));
            }
        };
        *slot = Some(SessionStateV2::Pending(PendingSessionV2 {
            session_id: session_id.clone(),
            sender_ip: client_info.ip,
            cancel: cancelled.clone(),
        }));
        replaced
    };

    if let Some(replaced) = replaced {
        tracing::info!("Upload session {replaced} continued by {session_id}");
        let _ = v2
            .event_tx
            .send(ServerEventV2::SessionEnd {
                session_id: replaced,
                reason: SessionEndReasonV2::Replaced,
            })
            .await;
    }

    // Frees the slot again if this request is aborted before a session is created.
    let mut pending_guard = PendingSessionGuard::new(v2.clone(), session_id.clone());

    let (decision_tx, decision_rx) = oneshot::channel();
    let event = ServerEventV2::PrepareUpload {
        session_id: session_id.clone(),
        ip: client_info.ip,
        info: payload.info,
        cert_fingerprint: cert_fingerprint.clone(),
        files: payload.files.clone(),
        resume: resume.clone(),
        decision_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    // The sender may cancel the request while the application is deciding.
    // Returning with the guard still armed frees the slot and emits
    // [ServerEventV2::PrepareUploadAborted], like a dropped connection.
    let decision = tokio::select! {
        decision = decision_rx => {
            decision.map_err(|_| AppError::Status(StatusCode::INTERNAL_SERVER_ERROR))?
        }
        _ = cancelled.cancelled() => {
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Cancelled by sender".to_string(),
            ));
        }
    };

    let (accepted_ids, offsets) = match decision {
        PrepareUploadDecisionV2::Decline => {
            pending_guard.clear().await;
            return Err(AppError::Message(
                StatusCode::FORBIDDEN,
                "Rejected".to_string(),
            ));
        }
        PrepareUploadDecisionV2::Accept(ids) => (ids, HashMap::new()),
        PrepareUploadDecisionV2::AcceptWithOffsets(ids, offsets) => (ids, offsets),
    };

    let files: HashMap<String, SessionFileV2> = payload
        .files
        .into_iter()
        .filter(|(id, _)| accepted_ids.contains(id))
        .map(|(id, dto)| {
            // Shuttle: only a file with a checksum can be continued, because
            // the checksum is what proves that the parts belong together.
            let resume_offset = match resume.is_some() && dto.sha256.is_some() {
                true => offsets
                    .get(&id)
                    .copied()
                    .filter(|offset| *offset <= dto.size),
                false => None,
            };
            let file = SessionFileV2 {
                dto,
                token: Uuid::new_v4().to_string(),
                status: FileStatusV2::Pending,
                attempts: 0,
                resume_offset,
            };
            (id, file)
        })
        .collect();

    if files.is_empty() {
        // Nothing to transfer.
        pending_guard.clear().await;
        let mut res = Response::new(empty_body());
        *res.status_mut() = StatusCode::NO_CONTENT;
        return Ok(res);
    }

    let tokens: HashMap<String, String> = files
        .iter()
        .map(|(id, file)| (id.clone(), file.token.clone()))
        .collect();

    // Shuttle: answered whenever the sender asked, so it learns that this
    // receiver can continue uploads, even if no file can be continued now.
    let resume_offsets = resume.as_ref().map(|_| {
        files
            .iter()
            .filter_map(|(id, file)| file.resume_offset.map(|offset| (id.clone(), offset)))
            .collect::<HashMap<String, u64>>()
    });

    {
        let mut slot = v2.session.lock().await;
        *slot = Some(SessionStateV2::Active(UploadSessionV2 {
            session_id: session_id.clone(),
            sender_ip: client_info.ip,
            sender_cert: cert_fingerprint,
            abort: CancellationToken::new(),
            files,
        }));
    }
    pending_guard.disarm();

    tracing::info!("Upload session created: {session_id}");

    Ok(JsonResponse {
        status: StatusCode::OK,
        body: PrepareUploadResponseDtoV2 {
            session_id,
            files: tokens,
            shuttle_resume: resume_offsets,
        },
    }
    .into_response())
}

pub(crate) async fn upload(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());

    let (Some(session_id), Some(file_id), Some(token)) = (
        query.get("sessionId"),
        query.get("fileId"),
        query.get("token"),
    ) else {
        return Err(AppError::Message(
            StatusCode::BAD_REQUEST,
            "Missing parameters".to_string(),
        ));
    };

    // Shuttle: the upload continues an earlier one at this offset.
    let requested_offset = match query.get("offset") {
        None => None,
        Some(offset) => Some(offset.parse::<u64>().map_err(|_| {
            AppError::Message(StatusCode::BAD_REQUEST, "Invalid offset".to_string())
        })?),
    };

    // Validate the request and mark the file as in progress.
    let (file_dto, offset, resumable, abort) = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return Err(invalid_token_error());
        };
        if session.session_id != *session_id || session.sender_ip != client_info.ip {
            return Err(invalid_token_error());
        }
        let Some(file) = session.files.get_mut(file_id) else {
            return Err(invalid_token_error());
        };
        if file.token != *token || file.status != FileStatusV2::Pending {
            return Err(invalid_token_error());
        }
        // Only the offset named in the prepare-upload answer (or none, i.e.
        // the whole file) is accepted, like an Upload-Offset in tus.
        let offset = match (requested_offset, file.resume_offset) {
            (None | Some(0), _) => 0,
            (Some(requested), Some(granted)) if requested == granted => requested,
            _ => return Err(offset_mismatch_error()),
        };
        file.status = FileStatusV2::InProgress;
        file.attempts = file.attempts.saturating_add(1);
        (
            file.dto.clone(),
            offset,
            file.resume_offset.is_some(),
            session.abort.child_token(),
        )
    };

    // Marks the file as failed if this request is aborted mid-transfer.
    let mut upload_guard = UploadGuard::new(v2.clone(), session_id.clone(), file_id.clone());

    let file_size = file_dto.size;
    // Shuttle: a continuable file is always verified, because the checksum is
    // what proves that the parts received at different times belong together.
    let expected_sha256 = match v2.verify_checksums || resumable {
        true => file_dto.sha256.clone(),
        false => None,
    };
    let timestamps = match &file_dto.metadata {
        Some(metadata) => FileTimestamps {
            modified: metadata.modified_time(),
            accessed: metadata.accessed_time(),
        },
        None => FileTimestamps::default(),
    };
    let (target_tx, target_rx) = oneshot::channel::<FileUploadTarget>();

    let event = ServerEventV2::FileUpload {
        session_id: session_id.clone(),
        file_id: file_id.clone(),
        file: file_dto,
        offset,
        resumable,
        target_tx,
    };
    if v2.event_tx.send(event).await.is_err() {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    let Ok(target) = target_rx.await else {
        upload_guard.finish(SaveResult::Failed).await;
        return Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR));
    };

    let result = common::save::save_req_to_target(
        req,
        target,
        UploadParams {
            file_size,
            offset,
            resumable,
            expected_sha256,
            timestamps,
        },
        abort,
    )
    .await;

    upload_guard.finish(result).await;

    match result {
        SaveResult::Success => Ok(Response::new(empty_body())),
        SaveResult::Failed => Err(AppError::Status(StatusCode::INTERNAL_SERVER_ERROR)),
        SaveResult::HashMismatch => Err(AppError::Message(
            StatusCode::UNPROCESSABLE_ENTITY,
            "Checksum mismatch".to_string(),
        )),
        SaveResult::OffsetMismatch => Err(offset_mismatch_error()),
    }
}

pub(crate) async fn cancel(
    req: Request<Incoming>,
    state: AppState,
    client_info: RequestClientInfo,
) -> Result<Response<BoxedBody>, AppError> {
    let v2 = require_v2(&state)?;
    let query = parse_query(req.uri().query());
    let session_id = query.get("sessionId");

    // A pending prepare-upload request: the sender does not know the session
    // ID yet (it is part of the response), so a cancel from the pending
    // sender's address is accepted without one.
    let pending_cancelled = {
        let slot = v2.session.lock().await;
        match slot.as_ref() {
            Some(SessionStateV2::Pending(pending))
                if pending.sender_ip == client_info.ip
                    && session_id.is_none_or(|id| *id == pending.session_id) =>
            {
                tracing::info!(
                    "Pending upload session cancelled by sender: {}",
                    pending.session_id
                );
                // The waiting prepare-upload handler frees the slot and
                // notifies the application.
                pending.cancel.cancel();
                true
            }
            _ => false,
        }
    };

    if pending_cancelled {
        return Ok(Response::new(empty_body()));
    }

    if let Some(session_id) = session_id {
        let cancelled = {
            let mut slot = v2.session.lock().await;
            match slot.as_ref() {
                Some(SessionStateV2::Active(session))
                    if session.session_id == *session_id && session.sender_ip == client_info.ip =>
                {
                    *slot = None;
                    true
                }
                _ => false,
            }
        };

        if cancelled {
            tracing::info!("Upload session cancelled by sender: {session_id}");
            let _ = v2
                .event_tx
                .send(ServerEventV2::SessionEnd {
                    session_id: session_id.clone(),
                    reason: SessionEndReasonV2::Cancelled,
                })
                .await;
        } else {
            // Not one of our upload sessions: the remote device may be
            // cancelling a transfer this application is sending to it.
            let _ = v2
                .event_tx
                .send(ServerEventV2::CancelReceived {
                    ip: client_info.ip,
                    session_id: session_id.clone(),
                })
                .await;
        }
    }

    Ok(Response::new(empty_body()))
}

fn require_v2(state: &AppState) -> Result<Arc<V2State>, AppError> {
    state
        .v2
        .clone()
        .ok_or(AppError::Status(StatusCode::NOT_FOUND))
}

fn invalid_token_error() -> AppError {
    AppError::Message(
        StatusCode::FORBIDDEN,
        "Invalid token or IP address".to_string(),
    )
}

/// Shuttle: the upload names an offset this server cannot continue from.
/// The sender should upload the whole file (offset 0) instead.
fn offset_mismatch_error() -> AppError {
    AppError::Message(StatusCode::CONFLICT, "Offset mismatch".to_string())
}

/// Shuttle: whether a prepare-upload request continues `active`, i.e. comes
/// from the same sender certificate and names that session in `resume_of`.
/// Without a certificate on either side there is nothing to bind it to.
fn is_continuation_of(
    active: &UploadSessionV2,
    resume: Option<&ShuttleResumeRequest>,
    cert_fingerprint: Option<&str>,
) -> bool {
    let Some(resume_of) = resume.and_then(|resume| resume.resume_of.as_deref()) else {
        return false;
    };
    let (Some(active_cert), Some(cert)) = (active.sender_cert.as_deref(), cert_fingerprint) else {
        return false;
    };
    resume_of == active.session_id && active_cert == cert
}

/// Frees a claimed `Pending` session slot unless a session was created.
///
/// The cleanup also runs on drop so the slot is not leaked
/// when the request future is cancelled (e.g. the sender disconnected
/// while the application was still deciding).
struct PendingSessionGuard {
    v2: Arc<V2State>,
    session_id: String,
    armed: bool,
}

impl PendingSessionGuard {
    fn new(v2: Arc<V2State>, session_id: String) -> Self {
        Self {
            v2,
            session_id,
            armed: true,
        }
    }

    /// Disarms the guard after the pending slot was replaced by an active session.
    fn disarm(&mut self) {
        self.armed = false;
    }

    /// Frees the pending slot immediately.
    async fn clear(&mut self) {
        self.armed = false;
        clear_pending_session(&self.v2).await;
    }
}

impl Drop for PendingSessionGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        tokio::spawn(async move {
            clear_pending_session(&v2).await;
            // The application may still be waiting for a decision; tell it
            // that answering is pointless now.
            let _ = v2
                .event_tx
                .send(ServerEventV2::PrepareUploadAborted { session_id })
                .await;
        });
    }
}

async fn clear_pending_session(v2: &V2State) {
    let mut slot = v2.session.lock().await;
    if matches!(*slot, Some(SessionStateV2::Pending(_))) {
        *slot = None;
    }
}

/// Sets the final status of a file after an upload attempt.
///
/// The cleanup also runs on drop (as a failure) so the file is not stuck
/// in progress when the request future is cancelled mid-transfer.
struct UploadGuard {
    v2: Arc<V2State>,
    session_id: String,
    file_id: String,
    armed: bool,
}

impl UploadGuard {
    fn new(v2: Arc<V2State>, session_id: String, file_id: String) -> Self {
        Self {
            v2,
            session_id,
            file_id,
            armed: true,
        }
    }

    async fn finish(&mut self, result: SaveResult) {
        self.armed = false;
        finalize_file(&self.v2, &self.session_id, &self.file_id, result).await;
    }
}

impl Drop for UploadGuard {
    fn drop(&mut self) {
        if !self.armed {
            return;
        }
        let v2 = self.v2.clone();
        let session_id = std::mem::take(&mut self.session_id);
        let file_id = std::mem::take(&mut self.file_id);
        tokio::spawn(async move {
            finalize_file(&v2, &session_id, &file_id, SaveResult::Failed).await;
        });
    }
}

/// How often an upload of the same file may be started, i.e. how often a
/// sender may retry a file after a checksum mismatch.
/// Senders must not retry more often than this (see the upload isolate).
const MAX_UPLOAD_ATTEMPTS: u8 = 3;

/// Sets the final status of a file and ends the session once all files are done.
///
/// A checksum mismatch resets the file to [FileStatusV2::Pending] (as long as
/// [MAX_UPLOAD_ATTEMPTS] is not exhausted) so the sender can retry the upload
/// with the same token; the session stays active in that case.
async fn finalize_file(v2: &V2State, session_id: &str, file_id: &str, result: SaveResult) {
    let session_ended = {
        let mut slot = v2.session.lock().await;
        let Some(SessionStateV2::Active(session)) = slot.as_mut() else {
            return;
        };
        if session.session_id != session_id {
            return;
        }
        if let Some(file) = session.files.get_mut(file_id) {
            if file.status == FileStatusV2::InProgress {
                // Shuttle: after an offset that could not be continued, the
                // sender uploads the whole file, like after a checksum mismatch.
                let retry = matches!(
                    result,
                    SaveResult::HashMismatch | SaveResult::OffsetMismatch
                );
                file.status = match result {
                    SaveResult::Success => FileStatusV2::Finished,
                    _ if retry && file.attempts < MAX_UPLOAD_ATTEMPTS => FileStatusV2::Pending,
                    _ => FileStatusV2::Failed,
                };
                // Nothing received so far can be continued.
                if retry && file.resume_offset.is_some() {
                    file.resume_offset = Some(0);
                }
            }
        }
        match session.is_complete() {
            true => {
                *slot = None;
                true
            }
            false => false,
        }
    };

    if session_ended {
        tracing::info!("Upload session finished: {session_id}");
        let _ = v2
            .event_tx
            .send(ServerEventV2::SessionEnd {
                session_id: session_id.to_string(),
                reason: SessionEndReasonV2::Finished,
            })
            .await;
    }
}
