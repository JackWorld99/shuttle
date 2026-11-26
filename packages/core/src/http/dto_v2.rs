use crate::model::discovery::DeviceType;
use crate::model::transfer::FileDto;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// Discovery types are shared with the (HTTP-independent) multicast module and
// therefore live in `crate::model::discovery`. They are re-exported here so that
// the v2 DTOs remain available under a single path.
use crate::model::discovery::ProtocolType;
use crate::model::discovery::{device_type_v2, protocol_type_v2};

/// Register request DTO for v2.2 protocol.
///
/// Sent to POST /api/localsend/v2/register for device discovery.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model (e.g., "Samsung", "Windows"). Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    /// Ignored in HTTPS mode (certificate is used instead).
    pub fingerprint: String,

    /// Port number the device is listening on.
    pub port: u16,

    /// Protocol type (http or https).
    #[serde(with = "protocol_type_v2")]
    pub protocol: ProtocolType,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

/// Register response DTO for v2.2 protocol.
///
/// Response from POST /api/localsend/v2/register.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RegisterResponseDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model. Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    /// Ignored in HTTPS mode (certificate is used instead).
    #[serde(default)]
    pub fingerprint: String,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

/// Prepare upload request DTO for v2.2 protocol.
///
/// Sent to POST /api/localsend/v2/prepare-upload to initiate a file transfer.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadRequestDtoV2 {
    /// Sender's device information.
    pub info: RegisterDtoV2,

    /// Map of file ID to file metadata.
    pub files: HashMap<String, FileDto>,

    /// Shuttle: the sender can continue interrupted uploads (see [ShuttleResumeRequest]).
    /// Not part of the LocalSend protocol; receivers that do not know it ignore it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shuttle_resume: Option<ShuttleResumeRequest>,
}

/// Shuttle's resume extension of `prepare-upload` (not part of the LocalSend protocol).
///
/// A sender that sets it can upload a file starting at an offset the receiver
/// names in [PrepareUploadResponseDtoV2::shuttle_resume], via the `offset`
/// query parameter of `upload`. The receiver keeps the part of a file it
/// received before a connection was lost and offers to continue it when the
/// same sender (identified by its client certificate) offers the same file
/// (identified by its SHA-256 and size) again.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShuttleResumeRequest {
    /// Version of the extension, currently 1.
    pub v: u32,

    /// The receiver's session ID of an upload that this request continues
    /// after the connection was lost. The receiver may then replace that
    /// session if it is still active (it has not noticed the lost connection
    /// yet) and skip asking its user again.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resume_of: Option<String>,
}

/// The version of [ShuttleResumeRequest] implemented here.
pub const SHUTTLE_RESUME_VERSION: u32 = 1;

/// Prepare upload response DTO for v2.2 protocol.
///
/// Response from POST /api/localsend/v2/prepare-upload.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareUploadResponseDtoV2 {
    /// Session ID for the file transfer.
    pub session_id: String,

    /// Map of file ID to file token.
    /// Only contains files that were accepted by the receiver.
    pub files: HashMap<String, String>,

    /// Shuttle: map of file ID to the offset the upload of that file starts at,
    /// for the files the receiver can continue (see [ShuttleResumeRequest]).
    /// Only sent in answer to a request with `shuttleResume`. A file listed here
    /// must be uploaded with the `offset` query parameter; an offset of 0 means
    /// that nothing was received yet but the upload can be continued later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shuttle_resume: Option<HashMap<String, u64>>,
}

pub struct PrepareUploadResultV2 {
    pub status_code: u16,
    pub response: Option<PrepareUploadResponseDtoV2>,
}

/// Prepare download response DTO for v2.2 protocol (Download API).
///
/// Response from POST /api/localsend/v2/prepare-download.
/// Used when the sender provides files for others to download.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrepareDownloadResponseDtoV2 {
    /// Sender's device information.
    pub info: InfoResponseDtoV2,

    /// Session ID for the download session.
    pub session_id: String,

    /// Map of file ID to file metadata.
    pub files: HashMap<String, FileDto>,
}

/// Info response DTO for v2.2 protocol.
///
/// Response from GET /api/localsend/v2/info.
/// Also used as the `info` field in PrepareDownloadResponseDtoV2.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoResponseDtoV2 {
    /// The display name of the device.
    pub alias: String,

    /// Protocol version (e.g., "2.0", "2.2").
    pub version: String,

    /// Device model. Optional.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub device_model: Option<String>,

    /// Device type category. Optional.
    #[serde(
        default,
        with = "device_type_v2",
        skip_serializing_if = "Option::is_none"
    )]
    pub device_type: Option<DeviceType>,

    /// Fingerprint for device identification.
    pub fingerprint: String,

    /// Whether the download API (sections 5.2, 5.3) is active.
    #[serde(default)]
    pub download: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_register_dto_v2_deserialization() {
        let json = r#"{
            "alias": "Secret Banana",
            "version": "2.0",
            "deviceModel": "Windows",
            "deviceType": "desktop",
            "fingerprint": "random string",
            "port": 53317,
            "protocol": "https",
            "download": true
        }"#;

        let dto: RegisterDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.alias, "Secret Banana");
        assert_eq!(dto.version, "2.0");
        assert_eq!(dto.device_model, Some("Windows".to_string()));
        assert_eq!(dto.device_type, Some(DeviceType::Desktop));
        assert_eq!(dto.fingerprint, "random string");
        assert_eq!(dto.port, 53317);
        assert_eq!(dto.protocol, ProtocolType::Https);
        assert!(dto.download);
    }

    #[test]
    fn test_device_type_unknown_falls_back_to_desktop() {
        // Unknown device types must fall back to desktop (protocol section 7.1).
        let json = r#"{
            "alias": "Test Device",
            "version": "2.0",
            "deviceType": "fridge",
            "fingerprint": "abc123",
            "port": 53317,
            "protocol": "http"
        }"#;

        let dto: RegisterDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.device_type, Some(DeviceType::Desktop));
    }

    #[test]
    fn test_register_response_without_download_field() {
        // Test that download defaults to false when not present
        let json = r#"{
            "alias": "Test Device",
            "version": "2.0",
            "fingerprint": "abc123"
        }"#;

        let dto: RegisterResponseDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(dto.alias, "Test Device");
        assert!(!dto.download);
    }

    #[test]
    fn test_prepare_upload_request_v2() {
        let request = PrepareUploadRequestDtoV2 {
            info: RegisterDtoV2 {
                alias: "Sender".to_string(),
                version: "2.2".to_string(),
                device_model: None,
                device_type: None,
                fingerprint: "sender-fingerprint".to_string(),
                port: 53317,
                protocol: ProtocolType::Https,
                download: false,
            },
            files: HashMap::from([(
                "file1".to_string(),
                FileDto {
                    id: "file1".to_string(),
                    file_name: "test.png".to_string(),
                    size: 1024,
                    file_type: "image/png".to_string(),
                    sha256: None,
                    preview: None,
                    metadata: None,
                },
            )]),
            shuttle_resume: None,
        };

        let json = serde_json::to_string(&request).unwrap();
        assert!(json.contains("\"info\""));
        assert!(json.contains("\"files\""));
        assert!(json.contains("\"fingerprint\":\"sender-fingerprint\""));
        // Peers that do not know the resume extension never see it
        assert!(!json.contains("shuttleResume"));
    }

    #[test]
    fn test_shuttle_resume_round_trip() {
        let json = r#"{
            "info": {"alias": "A", "version": "2.1", "fingerprint": "f", "port": 1, "protocol": "https"},
            "files": {},
            "shuttleResume": {"v": 1, "resumeOf": "old-session"}
        }"#;
        let request: PrepareUploadRequestDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(
            request.shuttle_resume,
            Some(ShuttleResumeRequest {
                v: 1,
                resume_of: Some("old-session".to_string()),
            })
        );

        let response: PrepareUploadResponseDtoV2 = serde_json::from_str(
            r#"{"sessionId": "s", "files": {"a": "t"}, "shuttleResume": {"a": 42}}"#,
        )
        .unwrap();
        assert_eq!(
            response.shuttle_resume,
            Some(HashMap::from([("a".to_string(), 42)]))
        );

        // A LocalSend receiver's answer has no offsets
        let response: PrepareUploadResponseDtoV2 =
            serde_json::from_str(r#"{"sessionId": "s", "files": {"a": "t"}}"#).unwrap();
        assert_eq!(response.shuttle_resume, None);
    }

    #[test]
    fn test_unknown_fields_are_ignored() {
        // A future version of the extension (or of LocalSend) may add fields
        let json = r#"{
            "info": {"alias": "A", "version": "2.1", "fingerprint": "f", "port": 1, "protocol": "https"},
            "files": {},
            "shuttleResume": {"v": 2, "somethingNew": true},
            "somethingElse": 1
        }"#;
        let request: PrepareUploadRequestDtoV2 = serde_json::from_str(json).unwrap();
        assert_eq!(request.shuttle_resume.map(|r| r.v), Some(2));
    }
}
