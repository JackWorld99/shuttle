use crate::crypto;
use bytes::Bytes;
use http_body_util::BodyExt;
use hyper::body::Incoming;
use hyper::Request;
use sha2::{Digest, Sha256};
use std::future::Future;
use std::path::PathBuf;
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;

/// Channel capacity for file upload chunks (provides backpressure).
const UPLOAD_CHANNEL_CAPACITY: usize = 16;

/// Size of the write buffer that coalesces incoming body chunks (typically one
/// TLS record, ~16 KiB) into larger file writes.
const WRITE_BUFFER_SIZE: usize = 512 * 1024;

/// Shuttle: how much of a continuable upload ([UploadParams::resumable]) is
/// written between two points at which the file is synced to disk and
/// reported on `saved_tx`. After a crash or a power loss, the upload continues
/// from the last such point.
pub const SYNC_INTERVAL: u64 = 64 * 1024 * 1024;

/// Buffer size for reading back the part of a file received earlier.
const PREFIX_READ_BUFFER_SIZE: usize = 1024 * 1024;

/// Where the content of an uploaded file should go, decided by the application.
#[derive(Debug)]
pub enum FileUploadTarget {
    /// The application consumes the binary chunks itself.
    ///
    /// The server forwards chunks into `binary_tx` and closes it at end of file.
    /// The application should compare the number of received bytes with `file.size`
    /// and report the result on the sender side of `result_rx` which determines
    /// the HTTP response (200 on `Ok`, 500 on `Err` or when the sender is dropped).
    ///
    /// Note: the checksum is only verified after the application reported its
    /// result, so a checksum mismatch is not observable by the application here
    /// (unlike [FileUploadTarget::Path] and [FileUploadTarget::Fd]).
    ///
    /// An upload consumed this way cannot be continued at an offset.
    Stream {
        /// Channel the server sends the binary chunks of the file into.
        binary_tx: mpsc::Sender<Bytes>,

        /// Channel on which the application reports whether the file was
        /// processed successfully.
        result_rx: oneshot::Receiver<Result<(), String>>,
    },

    /// The server writes the file to this path (created or truncated)
    /// and reports the result on `result_tx`.
    ///
    /// When the upload continues an earlier one at an offset (Shuttle's resume
    /// extension), the existing file is cut to that offset and written from
    /// there instead; the part it already holds is read back to verify the
    /// checksum of the whole file.
    ///
    /// Timestamps provided in the sender's file metadata are applied to the
    /// written file, so the application does not need to set them itself.
    Path {
        /// The path to write the file to.
        path: PathBuf,

        /// Channel on which the server reports whether the file was saved
        /// successfully, including the checksum verification if one was given.
        result_tx: oneshot::Sender<Result<(), String>>,

        /// Optional channel on which the server reports the number of bytes
        /// of the file written so far (including the part it held before an
        /// upload that continues at an offset). Events are dropped when the
        /// channel is full.
        progress_tx: Option<mpsc::Sender<u64>>,

        /// Shuttle: optional channel on which the server reports how much of a
        /// continuable upload is safely on disk, i.e. the offset the upload
        /// can be continued from: at least every [SYNC_INTERVAL] bytes, once
        /// more when the upload ends early (the connection was lost), and 0
        /// when the received content turned out to be unusable (checksum
        /// mismatch). Only used for uploads that can be continued.
        saved_tx: Option<mpsc::UnboundedSender<u64>>,
    },

    /// The server writes the file to this raw file descriptor (Android only)
    /// and reports the result on `result_tx`.
    ///
    /// Timestamps provided in the sender's file metadata are applied through
    /// the descriptor, which also covers SAF documents that have no path.
    ///
    /// For an upload that continues at an offset, the descriptor must be
    /// opened for reading and writing ("rw"): the part the file already holds
    /// is read back to verify the checksum.
    #[cfg(target_os = "android")]
    Fd {
        /// The raw file descriptor to write the file to.
        /// Ownership is transferred; the descriptor is closed after writing.
        fd: std::os::fd::RawFd,

        /// Channel on which the server reports whether the file was saved
        /// successfully, including the checksum verification if one was given.
        result_tx: oneshot::Sender<Result<(), String>>,

        /// Optional channel on which the server reports the number of bytes
        /// written so far, see [FileUploadTarget::Path].
        progress_tx: Option<mpsc::Sender<u64>>,

        /// Shuttle: see [FileUploadTarget::Path].
        saved_tx: Option<mpsc::UnboundedSender<u64>>,
    },
}

/// The sender-provided timestamps of an uploaded file, applied to the written
/// file for [FileUploadTarget::Path] and [FileUploadTarget::Fd].
#[derive(Debug, Clone, Copy, Default)]
pub struct FileTimestamps {
    pub modified: Option<std::time::SystemTime>,
    pub accessed: Option<std::time::SystemTime>,
}

impl FileTimestamps {
    fn is_empty(&self) -> bool {
        self.modified.is_none() && self.accessed.is_none()
    }
}

/// How an upload request is written to its target.
#[derive(Debug, Clone, Default)]
pub struct UploadParams {
    /// The size of the complete file.
    pub file_size: u64,

    /// Shuttle: the number of bytes of the file the target already holds from
    /// an earlier, interrupted upload. The request body carries the rest.
    pub offset: u64,

    /// Shuttle: whether the upload can be continued later. The received part
    /// is then synced to disk regularly and reported on `saved_tx`.
    pub resumable: bool,

    /// The SHA-256 (hex) the complete file must have, if it is to be verified.
    pub expected_sha256: Option<String>,

    /// The sender-provided timestamps applied to the written file.
    pub timestamps: FileTimestamps,
}

/// Outcome of receiving an uploaded file.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SaveResult {
    /// The file has been received and, if a checksum was given, it matched.
    Success,

    /// The body could not be read or the target failed to process it.
    Failed,

    /// The received bytes do not match the expected SHA-256 checksum.
    HashMismatch,

    /// Shuttle: the upload continues at an offset the target cannot continue
    /// from (the partial file is gone or shorter than that).
    OffsetMismatch,
}

/// Forwards the body of `req` to `target`.
///
/// Cancelling `abort` stops reading the body, like a lost connection: the
/// upload ends as [SaveResult::Failed] and a continuable upload reports the
/// part received so far.
pub(crate) async fn save_req_to_target(
    req: Request<Incoming>,
    target: FileUploadTarget,
    params: UploadParams,
    abort: CancellationToken,
) -> SaveResult {
    let body = req.into_body();
    match target {
        FileUploadTarget::Stream {
            binary_tx,
            result_rx,
        } => {
            if params.offset > 0 {
                tracing::warn!("Cannot continue an upload consumed by the application");
                return SaveResult::OffsetMismatch;
            }
            save_body_to_stream(
                body,
                binary_tx,
                result_rx,
                params.expected_sha256.as_deref(),
                &abort,
            )
            .await
        }
        FileUploadTarget::Path {
            path,
            result_tx,
            progress_tx,
            saved_tx,
        } => {
            let offset = params.offset;
            let open = async move { open_path(path, offset).await };
            save_body_to_file(body, open, result_tx, progress_tx, saved_tx, params, &abort).await
        }
        #[cfg(target_os = "android")]
        FileUploadTarget::Fd {
            fd,
            result_tx,
            progress_tx,
            saved_tx,
        } => {
            let open = async move {
                use std::os::fd::FromRawFd;

                // SAFETY: the descriptor is owned by this transfer; wrapping it in
                // a File transfers that ownership so it is closed once writing finishes.
                let std_file = unsafe { std::fs::File::from_raw_fd(fd) };
                Ok(tokio::fs::File::from_std(std_file))
            };
            save_body_to_file(body, open, result_tx, progress_tx, saved_tx, params, &abort).await
        }
    }
}

/// Forwards the body to a stream the application consumes itself
/// ([FileUploadTarget::Stream]), hashing it on the way if requested.
async fn save_body_to_stream(
    body: Incoming,
    binary_tx: mpsc::Sender<Bytes>,
    result_rx: oneshot::Receiver<Result<(), String>>,
    expected_sha256: Option<&str>,
    abort: &CancellationToken,
) -> SaveResult {
    let mut hasher = expected_sha256.map(|_| Sha256::new());
    let complete = forward_body(body, &binary_tx, hasher.as_mut(), abort).await;

    // Signal end of file to the application.
    drop(binary_tx);

    if !complete {
        return SaveResult::Failed;
    }

    match result_rx.await {
        Ok(Ok(())) => (),
        Ok(Err(err)) => {
            tracing::warn!("Failed to process file: {err}");
            return SaveResult::Failed;
        }
        Err(_) => return SaveResult::Failed,
    }

    if let (Some(hasher), Some(expected)) = (hasher, expected_sha256) {
        let actual = crypto::hash::to_hex(&hasher.finalize());
        if !actual.eq_ignore_ascii_case(expected) {
            tracing::warn!("Checksum mismatch: expected {expected}, got {actual}");
            return SaveResult::HashMismatch;
        }
    }

    SaveResult::Success
}

/// Forwards the body to a file written by the server ([FileUploadTarget::Path]
/// and [FileUploadTarget::Fd]).
///
/// The file writer reports the outcome to the application on
/// `app_result_tx`, also when this request is dropped mid-transfer (the
/// connection was lost): the writer then sees the end of the chunks and
/// fails with a size mismatch, which also reports the part saved so far of a
/// continuable upload.
async fn save_body_to_file(
    body: Incoming,
    open: impl Future<Output = Result<tokio::fs::File, WriteError>> + Send + 'static,
    app_result_tx: oneshot::Sender<Result<(), String>>,
    progress_tx: Option<mpsc::Sender<u64>>,
    saved_tx: Option<mpsc::UnboundedSender<u64>>,
    params: UploadParams,
    abort: &CancellationToken,
) -> SaveResult {
    let (binary_tx, outcome_rx) =
        spawn_file_writer(open, params, progress_tx, saved_tx, app_result_tx);

    forward_body(body, &binary_tx, None, abort).await;

    // Signal end of file to the writer. If the body was incomplete, the writer
    // fails with a size mismatch.
    drop(binary_tx);

    outcome_rx.await.unwrap_or(SaveResult::Failed)
}

/// Forwards the data frames of `body` to `binary_tx`, hashing them if
/// `hasher` is given.
///
/// Returns `false` when the body could not be read completely: it failed
/// (e.g. the connection was lost), the receiving side is gone, or `abort` was
/// cancelled.
async fn forward_body(
    mut body: Incoming,
    binary_tx: &mpsc::Sender<Bytes>,
    mut hasher: Option<&mut Sha256>,
    abort: &CancellationToken,
) -> bool {
    loop {
        let frame = tokio::select! {
            biased;
            _ = abort.cancelled() => {
                tracing::info!("Upload interrupted by a continuation of its session");
                return false;
            }
            frame = body.frame() => frame,
        };
        let Some(frame) = frame else {
            return true;
        };
        match frame {
            Ok(frame) => {
                let Ok(data) = frame.into_data() else {
                    continue; // ignore non-data frames (e.g. trailers)
                };
                if data.is_empty() {
                    continue;
                }
                if let Some(hasher) = hasher.as_mut() {
                    hasher.update(&data);
                }
                // Sending waits while the receiving side is busy (backpressure),
                // which an abort must interrupt as well.
                let sent = tokio::select! {
                    biased;
                    _ = abort.cancelled() => return false,
                    sent = binary_tx.send(data) => sent,
                };
                if sent.is_err() {
                    // The receiver is gone (dropped by the application or
                    // closed by the file writer after an error).
                    return false;
                }
            }
            Err(err) => {
                tracing::warn!("Error reading upload body of file: {err:#}");
                return false;
            }
        }
    }
}

/// Why writing a file failed, and how the upload request ends because of it.
#[derive(Debug)]
struct WriteError {
    result: SaveResult,
    message: String,
}

impl WriteError {
    fn failed(message: String) -> Self {
        WriteError {
            result: SaveResult::Failed,
            message,
        }
    }

    fn offset_mismatch(message: String) -> Self {
        WriteError {
            result: SaveResult::OffsetMismatch,
            message,
        }
    }
}

/// Opens `path` for an upload: created (or truncated) for a new upload, opened
/// for reading and writing to continue one at `offset`.
async fn open_path(path: PathBuf, offset: u64) -> Result<tokio::fs::File, WriteError> {
    if offset == 0 {
        return tokio::fs::File::create(&path)
            .await
            .map_err(|e| WriteError::failed(format!("Failed to create {}: {e}", path.display())));
    }

    tokio::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(&path)
        .await
        .map_err(|e| {
            let message = format!("Failed to open {}: {e}", path.display());
            match e.kind() {
                std::io::ErrorKind::NotFound => WriteError::offset_mismatch(message),
                _ => WriteError::failed(message),
            }
        })
}

/// Spawns a task that writes incoming chunks to a file provided by `open`.
///
/// The task reports the outcome to the application on `app_result_tx`.
/// Returns the sender for the binary chunks and a receiver for the outcome of
/// the request.
fn spawn_file_writer(
    open: impl Future<Output = Result<tokio::fs::File, WriteError>> + Send + 'static,
    params: UploadParams,
    progress_tx: Option<mpsc::Sender<u64>>,
    saved_tx: Option<mpsc::UnboundedSender<u64>>,
    app_result_tx: oneshot::Sender<Result<(), String>>,
) -> (mpsc::Sender<Bytes>, oneshot::Receiver<SaveResult>) {
    let (binary_tx, mut binary_rx) = mpsc::channel::<Bytes>(UPLOAD_CHANNEL_CAPACITY);
    let (outcome_tx, outcome_rx) = oneshot::channel::<SaveResult>();

    tokio::spawn(async move {
        let result = write_file_from_receiver(
            open,
            &params,
            &mut binary_rx,
            progress_tx,
            saved_tx.as_ref(),
        )
        .await;
        // Unblock the request handler if it is still sending chunks.
        binary_rx.close();

        let (outcome, app_result) = match result {
            Ok(()) => (SaveResult::Success, Ok(())),
            Err(err) => {
                tracing::warn!("Failed to save file: {}", err.message);
                (err.result, Err(err.message))
            }
        };
        let _ = app_result_tx.send(app_result);
        let _ = outcome_tx.send(outcome);
    });

    (binary_tx, outcome_rx)
}

/// Writes all chunks received on `rx` to the file provided by `open`.
///
/// Fails if the total number of written bytes does not match the file size
/// (e.g. the sender disconnected mid-transfer), or if a checksum was given
/// and the complete file does not match it.
///
/// The file is truncated to the written size, so that a target that pointed at
/// a longer, pre-existing file cannot keep a tail of the old content.
///
/// The sender-provided timestamps are applied to the completely written
/// file. This happens on the still-open handle: an Android file descriptor has
/// no path to address the file by afterwards.
///
/// Shuttle: an upload that continues at [UploadParams::offset] keeps the first
/// `offset` bytes of the file, reads them back into the checksum and appends
/// the received chunks. A continuable upload ([UploadParams::resumable]) is
/// synced to disk every [SYNC_INTERVAL] bytes and when it ends early, and the
/// synced size is reported on `saved_tx`.
async fn write_file_from_receiver(
    open: impl Future<Output = Result<tokio::fs::File, WriteError>>,
    params: &UploadParams,
    rx: &mut mpsc::Receiver<Bytes>,
    progress_tx: Option<mpsc::Sender<u64>>,
    saved_tx: Option<&mpsc::UnboundedSender<u64>>,
) -> Result<(), WriteError> {
    use tokio::io::{AsyncSeekExt, AsyncWriteExt};

    let expected_size = params.file_size;
    let offset = params.offset;
    let report_saved = |saved: u64| {
        if let Some(saved_tx) = saved_tx {
            let _ = saved_tx.send(saved);
        }
    };

    let mut file = open.await?;
    let mut hasher = params.expected_sha256.as_ref().map(|_| Sha256::new());

    if offset > 0 {
        let len = file
            .metadata()
            .await
            .map_err(|e| WriteError::failed(format!("Failed to read the partial file: {e}")))?
            .len();
        if len < offset {
            return Err(WriteError::offset_mismatch(format!(
                "The partial file holds {len} bytes, expected at least {offset}"
            )));
        }
        if len > offset {
            // Bytes after the last point reported as saved may not have reached
            // the disk before a crash, so they are not trusted.
            file.set_len(offset)
                .await
                .map_err(|e| WriteError::failed(format!("Failed to cut the partial file: {e}")))?;
        }
        if let Some(hasher) = &mut hasher {
            file.seek(std::io::SeekFrom::Start(0))
                .await
                .map_err(|e| WriteError::failed(format!("Failed to read the partial file: {e}")))?;
            hash_prefix(&mut file, offset, hasher)
                .await
                .map_err(|e| WriteError::failed(format!("Failed to read the partial file: {e}")))?;
        }
        file.seek(std::io::SeekFrom::Start(offset))
            .await
            .map_err(|e| WriteError::failed(format!("Failed to continue the partial file: {e}")))?;
        tracing::info!("Continuing a file at {offset} of {expected_size} bytes");
    }

    let mut file = tokio::io::BufWriter::with_capacity(WRITE_BUFFER_SIZE, file);
    let mut written: u64 = offset;
    let mut synced: u64 = offset;
    while let Some(chunk) = rx.recv().await {
        written += chunk.len() as u64;
        if written > expected_size {
            return Err(WriteError::failed(format!(
                "Expected {expected_size} bytes, received at least {written}"
            )));
        }
        file.write_all(&chunk)
            .await
            .map_err(|e| WriteError::failed(format!("Failed to write file: {e}")))?;
        if let Some(hasher) = &mut hasher {
            hasher.update(&chunk);
        }
        if let Some(progress_tx) = &progress_tx {
            // Progress is best-effort: drop the event when the consumer lags.
            let _ = progress_tx.try_send(written);
        }
        if params.resumable && written - synced >= SYNC_INTERVAL {
            file.flush()
                .await
                .map_err(|e| WriteError::failed(format!("Failed to flush file: {e}")))?;
            file.get_ref()
                .sync_data()
                .await
                .map_err(|e| WriteError::failed(format!("Failed to sync file: {e}")))?;
            synced = written;
            report_saved(synced);
        }
    }
    file.flush()
        .await
        .map_err(|e| WriteError::failed(format!("Failed to flush file: {e}")))?;
    let file = file.into_inner();

    if written != expected_size {
        if params.resumable {
            // The connection was lost: keep what arrived so the upload can be
            // continued from here. Reported even when nothing new arrived, so
            // the application knows the partial file is still intact. If
            // syncing fails, the last reported point is still valid.
            match written > synced {
                true => match file.sync_data().await {
                    Ok(()) => report_saved(written),
                    Err(e) => tracing::warn!("Could not sync the partial file: {e}"),
                },
                false => report_saved(written),
            }
        }
        return Err(WriteError::failed(format!(
            "Expected {expected_size} bytes, received {written}"
        )));
    }

    if let (Some(hasher), Some(expected)) = (hasher, &params.expected_sha256) {
        let actual = crypto::hash::to_hex(&hasher.finalize());
        if !actual.eq_ignore_ascii_case(expected) {
            tracing::warn!("Checksum mismatch: expected {expected}, got {actual}");
            if params.resumable {
                // Nothing of it can be continued.
                report_saved(0);
            }
            return Err(WriteError {
                result: SaveResult::HashMismatch,
                message: "Checksum mismatch".to_string(),
            });
        }
    }

    // Drops content beyond the file that was just written, in case the target
    // pointed at a longer, pre-existing file: opening truncates for paths and
    // for descriptors opened with the SAF "wt" mode, but a document provider is
    // free to ignore that mode. Retries of the same upload are covered by the
    // exact size check above either way.
    //
    // Best-effort: a provider may back the descriptor by something that cannot
    // be truncated (e.g. a pipe), which must not fail the completed transfer.
    if let Err(e) = file.set_len(written).await {
        tracing::warn!("Could not truncate file to {written} bytes: {e}");
    }

    // The timestamps are applied last because the writes and the truncation
    // above update the modification time themselves.
    //
    // Best-effort: the provider backing an Android file descriptor may not
    // support changing timestamps, which must not fail the completed transfer.
    let timestamps = params.timestamps;
    if !timestamps.is_empty() {
        let mut times = std::fs::FileTimes::new();
        if let Some(modified) = timestamps.modified {
            times = times.set_modified(modified);
        }
        if let Some(accessed) = timestamps.accessed {
            times = times.set_accessed(accessed);
        }
        let file = file.into_std().await;
        // Also closes the file, off the async runtime like tokio::fs does.
        let result = tokio::task::spawn_blocking(move || file.set_times(times)).await;
        if let Ok(Err(e)) = result {
            tracing::warn!("Could not set file timestamps: {e}");
        }
    }

    Ok(())
}

/// Reads the first `len` bytes of `file` into `hasher`.
async fn hash_prefix(
    file: &mut tokio::fs::File,
    len: u64,
    hasher: &mut Sha256,
) -> std::io::Result<()> {
    use tokio::io::AsyncReadExt;

    let mut buffer = vec![0_u8; PREFIX_READ_BUFFER_SIZE];
    let mut remaining = len;
    while remaining > 0 {
        let n = remaining.min(buffer.len() as u64) as usize;
        file.read_exact(&mut buffer[..n]).await?;
        hasher.update(&buffer[..n]);
        remaining -= n as u64;
    }
    Ok(())
}
