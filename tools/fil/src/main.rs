use std::env;
use std::fs::{self, OpenOptions};
use std::io::{self, IsTerminal, Read, Seek, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
#[cfg(unix)]
use std::os::unix::net::{UnixListener, UnixStream};
use std::process::Command;

/// RFC 4648 standard base64 encoding without external dependencies
pub fn base64_encode(data: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    let mut chunks = data.chunks_exact(3);
    for chunk in &mut chunks {
        let b0 = chunk[0];
        let b1 = chunk[1];
        let b2 = chunk[2];
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        out.push(TABLE[(b2 & 0x3f) as usize] as char);
    }
    let rem = chunks.remainder();
    if rem.len() == 1 {
        let b0 = rem[0];
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[((b0 & 0x03) << 4) as usize] as char);
        out.push('=');
        out.push('=');
    } else if rem.len() == 2 {
        let b0 = rem[0];
        let b1 = rem[1];
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        out.push(TABLE[((b1 & 0x0f) << 2) as usize] as char);
        out.push('=');
    }
    out
}

/// Formats an OSC 52 clipboard escape sequence
pub fn format_osc52(data: &[u8]) -> String {
    let b64 = base64_encode(data);
    format!("\x1b]52;c;{}\x07", b64)
}

/// Formats an OSC 777 notification escape sequence
pub fn format_osc777(title: &str, body: &str) -> String {
    format!("\x1b]777;notify;{};{}\x07", title, body)
}

/// Formats an OSC 5100 open-URL escape sequence for immediate Safari opening
pub fn format_osc_open(url: &str) -> String {
    format!("\x1b]5100;open;{}\x07", url)
}

/// Formats an OSC 5101 file preview chunk escape sequence for native Apple Quick Look
pub fn format_osc_preview_chunk(id: &str, name: &str, part: usize, total: usize, chunk: &str) -> String {
    let clean_name = name.replace(';', "_");
    format!("\x1b]5101;preview;id={};name={};part={};total={};{}\x07", id, clean_name, part, total, chunk)
}

/// Detects a suggested filename with extension from file magic bytes when reading stdin
pub fn detect_filename(data: &[u8]) -> String {
    if data.starts_with(b"\x89PNG\r\n\x1a\n") {
        "preview.png".to_string()
    } else if data.starts_with(b"\xff\xd8\xff") {
        "preview.jpg".to_string()
    } else if data.starts_with(b"GIF87a") || data.starts_with(b"GIF89a") {
        "preview.gif".to_string()
    } else if data.starts_with(b"%PDF-") {
        "preview.pdf".to_string()
    } else if data.starts_with(b"PK\x03\x04") {
        "preview.zip".to_string()
    } else if data.starts_with(b"\x1f\x8b") {
        "preview.gz".to_string()
    } else if data.starts_with(b"BZh") {
        "preview.bz2".to_string()
    } else if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WEBP" {
        "preview.webp".to_string()
    } else if data.len() >= 12 && &data[0..4] == b"RIFF" && &data[8..12] == b"WAVE" {
        "preview.wav".to_string()
    } else if data.len() >= 8 && (&data[4..8] == b"ftyp" || &data[4..8] == b"moov") {
        "preview.mp4".to_string()
    } else if data.starts_with(b"ID3") || (data.len() >= 2 && data[0] == 0xff && (data[1] & 0xe0) == 0xe0) {
        "preview.mp3".to_string()
    } else if let Ok(text) = std::str::from_utf8(&data[..data.len().min(2048)]) {
        let trimmed = text.trim();
        let lower = trimmed.to_lowercase();
        if lower.starts_with("<!doctype html") || lower.starts_with("<html") {
            "preview.html".to_string()
        } else if lower.starts_with("<svg") || (lower.starts_with("<?xml") && lower.contains("<svg")) {
            "preview.svg".to_string()
        } else if lower.starts_with("<?xml") {
            "preview.xml".to_string()
        } else if trimmed.starts_with('{') || trimmed.starts_with('[') {
            "preview.json".to_string()
        } else if trimmed.starts_with("---") || trimmed.starts_with("%YAML") {
            "preview.yaml".to_string()
        } else if trimmed.starts_with("# ") || trimmed.starts_with("## ") || trimmed.contains("```") {
            "preview.md".to_string()
        } else if trimmed.contains('\t') && trimmed.contains('\n') {
            "preview.tsv".to_string()
        } else if trimmed.contains(',') && trimmed.contains('\n') && !trimmed.contains('{') {
            let first_line = trimmed.lines().next().unwrap_or("");
            if first_line.contains(',') && first_line.split(',').count() >= 2 {
                "preview.csv".to_string()
            } else {
                "preview.txt".to_string()
            }
        } else {
            "preview.txt".to_string()
        }
    } else {
        "preview.txt".to_string()
    }
}

/// Wraps an escape sequence in tmux DCS passthrough (\ePtmux;\e\e...\e\)
/// with any inner escape characters doubled.
pub fn wrap_tmux_dcs(seq: &str) -> String {
    let escaped = seq.replace('\x1b', "\x1b\x1b");
    format!("\x1bPtmux;{}\x1b\\", escaped)
}

/// Enables tmux passthrough for the pane fil runs in, so its escape sequences reach Filaire even
/// while that window is hidden (e.g. `cargo build && fil notify`). Scoped to this pane only: a
/// window/global setting would let every program in every pane send sequences to the device.
pub fn ensure_tmux_passthrough() {
    let _ = Command::new("tmux").args(["set", "-p", "allow-passthrough", "all"]).output();
}

/// Raw chunk size: 6,144 bytes raw encodes into exactly 8,192 base64 characters.
pub const RAW_CHUNK_SIZE: usize = 6144;

/// Documented maximum preview input ceiling (100 MiB), matching the receiver hard budget.
pub const MAX_PREVIEW_BYTES: u64 = 100 * 1024 * 1024;

/// Destination writer for terminal escape sequences: either controlling terminal (/dev/tty) or stdout.
pub enum TerminalOutput {
    Tty(fs::File),
    Stdout(io::Stdout),
}

impl Write for TerminalOutput {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        match self {
            TerminalOutput::Tty(f) => f.write(buf),
            TerminalOutput::Stdout(s) => s.write(buf),
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        match self {
            TerminalOutput::Tty(f) => f.flush(),
            TerminalOutput::Stdout(s) => s.flush(),
        }
    }
}

/// Opens the controlling terminal (/dev/tty) once, falling back to stdout if /dev/tty cannot be opened.
pub fn open_terminal_writer() -> TerminalOutput {
    if let Ok(tty) = OpenOptions::new().write(true).open("/dev/tty") {
        TerminalOutput::Tty(tty)
    } else {
        TerminalOutput::Stdout(io::stdout())
    }
}

/// Writes an escape sequence to a terminal writer, applying tmux DCS wrapping if `in_tmux` is true.
/// For OSC 52 sequences inside tmux, it also writes the raw sequence so tmux can update its internal buffer.
pub fn write_osc_sequence<W: Write>(writer: &mut W, raw_seq: &str, in_tmux: bool) -> io::Result<()> {
    if in_tmux {
        let wrapped = wrap_tmux_dcs(raw_seq);
        writer.write_all(wrapped.as_bytes())?;
        if raw_seq.starts_with("\x1b]52;") {
            writer.write_all(raw_seq.as_bytes())?;
        }
    } else {
        writer.write_all(raw_seq.as_bytes())?;
    }
    Ok(())
}

/// Emits the escape sequences directly to the controlling terminal (/dev/tty),
/// falling back to stdout if /dev/tty is not available.
pub fn emit_to_terminal(raw_seq: &str, in_tmux: bool) -> io::Result<()> {
    let mut writer = open_terminal_writer();
    write_osc_sequence(&mut writer, raw_seq, in_tmux)?;
    writer.flush()?;
    Ok(())
}

/// Helper to fill a slice completely from a reader, retrying on interrupted and detecting unexpected EOF.
pub fn fill_exact<R: Read>(reader: &mut R, mut buf: &mut [u8]) -> io::Result<()> {
    while !buf.is_empty() {
        match reader.read(buf) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "Unexpected EOF while reading stream",
                ))
            }
            Ok(n) => buf = &mut buf[n..],
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

/// Streams a file preview to a destination writer in chunks of at most 6,144 raw bytes (8,192 base64 chars).
/// Returns the total number of bytes streamed.
pub fn stream_preview<R: Read, W: Write>(
    mut reader: R,
    total_bytes: u64,
    transfer_id: &str,
    filename: &str,
    in_tmux: bool,
    mut writer: W,
) -> io::Result<u64> {
    if total_bytes > MAX_PREVIEW_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!(
                "Input size {} bytes exceeds maximum preview limit of {} bytes (100 MiB)",
                total_bytes, MAX_PREVIEW_BYTES
            ),
        ));
    }

    let total_parts = if total_bytes == 0 {
        1
    } else {
        let chunk_size = RAW_CHUNK_SIZE as u64;
        let sum = total_bytes.checked_add(chunk_size - 1).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "Overflow computing total parts")
        })?;
        (sum / chunk_size) as usize
    };

    if total_bytes == 0 {
        let osc = format_osc_preview_chunk(transfer_id, filename, 1, 1, "");
        write_osc_sequence(&mut writer, &osc, in_tmux)?;
        writer.flush()?;
        return Ok(0);
    }

    let pace_ms = env::var("FIL_PREVIEW_PACE_MS")
        .ok()
        .and_then(|s| s.parse::<u64>().ok())
        .unwrap_or(0);

    let mut bytes_sent: u64 = 0;
    let mut raw_buf = [0u8; RAW_CHUNK_SIZE];

    for part in 1..=total_parts {
        let remaining = total_bytes.checked_sub(bytes_sent).ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "Byte count mismatch during transfer")
        })?;
        let to_read = (remaining as usize).min(RAW_CHUNK_SIZE);

        fill_exact(&mut reader, &mut raw_buf[..to_read])?;
        bytes_sent += to_read as u64;

        let b64_chunk = base64_encode(&raw_buf[..to_read]);
        let osc = format_osc_preview_chunk(transfer_id, filename, part, total_parts, &b64_chunk);
        write_osc_sequence(&mut writer, &osc, in_tmux)?;

        if pace_ms > 0 && part < total_parts {
            std::thread::sleep(std::time::Duration::from_millis(pace_ms));
        }
    }

    writer.flush()?;
    Ok(bytes_sent)
}

/// RAII guard for private exclusive temporary files created with mode 0600.
/// Automatically removes the temporary file when dropped.
pub struct TempFileGuard {
    pub path: PathBuf,
    pub file: fs::File,
}

impl TempFileGuard {
    pub fn new() -> io::Result<Self> {
        let temp_dir = env::temp_dir();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();

        for attempt in 0..100 {
            let file_name = format!(
                "fil_preview_{}_{}_{}_{}.tmp",
                std::process::id(),
                now.as_secs(),
                now.subsec_nanos(),
                attempt
            );
            let path = temp_dir.join(file_name);
            let mut opts = OpenOptions::new();
            opts.read(true).write(true).create_new(true);
            #[cfg(unix)]
            opts.mode(0o600);

            match opts.open(&path) {
                Ok(file) => return Ok(Self { path, file }),
                Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(e),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "Failed to create unique temporary file after 100 attempts",
        ))
    }
}

impl Drop for TempFileGuard {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

/// Spools a reader to an exclusive temporary file, bounding memory to a 64 KiB buffer,
/// enforcing `MAX_PREVIEW_BYTES`, capturing the first 2,048 bytes as prefix for filename detection,
/// and rewinding the temporary file handle to the beginning for streaming.
pub fn spool_to_temp<R: Read>(
    mut reader: R,
    max_bytes: u64,
) -> io::Result<(TempFileGuard, u64, Vec<u8>)> {
    let mut spool = TempFileGuard::new()?;
    let mut buf = [0u8; 65536];
    let mut total_spooled: u64 = 0;
    let mut prefix = Vec::with_capacity(2048);

    loop {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                total_spooled = total_spooled.checked_add(n as u64).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "Overflow counting spooled bytes")
                })?;
                if total_spooled > max_bytes {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!(
                            "Input exceeds maximum preview limit of {} bytes (100 MiB)",
                            max_bytes
                        ),
                    ));
                }
                if prefix.len() < 2048 {
                    let needed = 2048 - prefix.len();
                    prefix.extend_from_slice(&buf[..n.min(needed)]);
                }
                spool.file.write_all(&buf[..n])?;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }

    spool.file.flush()?;
    spool.file.seek(io::SeekFrom::Start(0))?;
    Ok((spool, total_spooled, prefix))
}

/// Copies content to iOS clipboard and updates local tmux buffer if active
fn copy_to_clipboard(data: &[u8]) -> io::Result<()> {
    let in_tmux = env::var("TMUX").is_ok();

    // If inside tmux, also synchronize the local tmux paste buffer
    if in_tmux {
        ensure_tmux_passthrough();
        if let Ok(text) = std::str::from_utf8(data) {
            let _ = Command::new("tmux")
                .args(["set-buffer", "--", text])
                .output();
        }
    }

    let osc = format_osc52(data);
    emit_to_terminal(&osc, in_tmux)?;
    Ok(())
}

/// Parses notify CLI arguments into (title, body).
/// Supports:
/// - fil notify <MSG> [-t TITLE]
/// - fil notify <TITLE> <BODY>
/// - fil notify (defaults to "Filaire", "Task completed")
pub fn parse_notify_args<S: AsRef<str>>(args: &[S]) -> (String, String) {
    let mut explicit_title: Option<String> = None;
    let mut positional = Vec::new();
    let mut iter = args.iter().peekable();

    while let Some(arg) = iter.next() {
        let s = arg.as_ref();
        if (s == "-t" || s == "--title") && iter.peek().is_some() {
            explicit_title = Some(iter.next().unwrap().as_ref().to_string());
        } else {
            positional.push(s);
        }
    }

    if let Some(t) = explicit_title {
        let body = if positional.is_empty() {
            "Task completed".to_string()
        } else {
            positional.join(" ")
        };
        (t, body)
    } else {
        match positional.len() {
            0 => ("Filaire".to_string(), "Task completed".to_string()),
            1 => ("Filaire".to_string(), positional[0].to_string()),
            2 => (positional[0].to_string(), positional[1].to_string()),
            _ => ("Filaire".to_string(), positional.join(" ")),
        }
    }
}

/// Sends a native notification to the Filaire iOS client
fn send_notification(title: &str, body: &str) -> io::Result<()> {
    let in_tmux = env::var("TMUX").is_ok();
    if in_tmux {
        ensure_tmux_passthrough();
    }
    let osc = format_osc777(title, body);
    emit_to_terminal(&osc, in_tmux)?;
    Ok(())
}

/// Opens a URL on the Filaire iOS client
fn open_url(url: &str) -> io::Result<()> {
    let in_tmux = env::var("TMUX").is_ok();
    if in_tmux {
        ensure_tmux_passthrough();
    }
    let osc = format_osc_open(url);
    emit_to_terminal(&osc, in_tmux)?;
    println!("Opened URL on iOS: {}", url);
    Ok(())
}

/// Sends a file or piped stdin to the Filaire iOS client for native Apple Quick Look preview.
/// 
/// Concurrently modified files:
/// fil snapshots the file's size at the start of transfer. If the file is truncated concurrently,
/// the transfer aborts with an UnexpectedEof error before completion. If the file grows concurrently,
/// only the initial snapshot length is transmitted.
pub fn preview_file(path: Option<&str>, explicit_name: Option<&str>) -> io::Result<()> {
    if path.is_none() && io::stdin().is_terminal() {
        eprintln!("Error: fil preview requires a file path or piped stdin.\nUsage: fil preview [FILE] [-n NAME]");
        std::process::exit(1);
    }

    let in_tmux = env::var("TMUX").is_ok();
    if in_tmux {
        ensure_tmux_passthrough();
    }

    let transfer_id = {
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        format!("{:x}{:x}{:x}", std::process::id(), now.as_secs(), now.subsec_nanos())
    };

    let mut terminal_writer = open_terminal_writer();

    match path {
        Some(p) => {
            let mut file = fs::File::open(p)?;
            let meta = file.metadata()?;

            // Check if regular file and seekable
            if meta.file_type().is_file() {
                let file_len = meta.len();
                if file_len > MAX_PREVIEW_BYTES {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        format!(
                            "File '{}' ({} bytes) exceeds maximum preview limit of {} bytes (100 MiB)",
                            p, file_len, MAX_PREVIEW_BYTES
                        ),
                    ));
                }

                let mut name = explicit_name.map(String::from).unwrap_or_else(|| {
                    Path::new(p)
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string()
                });

                if Path::new(&name).extension().is_none() {
                    let mut prefix = [0u8; 2048];
                    let mut n_read = 0;
                    while n_read < prefix.len() {
                        match file.read(&mut prefix[n_read..]) {
                            Ok(0) => break,
                            Ok(n) => n_read += n,
                            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                            Err(e) => return Err(e),
                        }
                    }
                    let detected = detect_filename(&prefix[..n_read]);
                    if let Some(ext) = Path::new(&detected).extension() {
                        name.push('.');
                        name.push_str(&ext.to_string_lossy());
                    }
                    file.seek(io::SeekFrom::Start(0))?;
                }

                let total_parts = if file_len == 0 {
                    1
                } else {
                    ((file_len + RAW_CHUNK_SIZE as u64 - 1) / RAW_CHUNK_SIZE as u64) as usize
                };
                let bytes_sent = stream_preview(
                    &mut file,
                    file_len,
                    &transfer_id,
                    &name,
                    in_tmux,
                    &mut terminal_writer,
                )?;

                println!(
                    "Sent '{}' ({} bytes, {} part{}) to iOS Quick Look preview.",
                    name,
                    bytes_sent,
                    total_parts,
                    if total_parts == 1 { "" } else { "s" }
                );
            } else {
                // Non-regular file (FIFO, device, etc.): spool to temporary file
                let (mut spool, spooled_len, prefix) = spool_to_temp(&mut file, MAX_PREVIEW_BYTES)?;
                let mut name = explicit_name.map(String::from).unwrap_or_else(|| {
                    Path::new(p)
                        .file_name()
                        .unwrap_or_default()
                        .to_string_lossy()
                        .to_string()
                });
                if Path::new(&name).extension().is_none() {
                    let detected = detect_filename(&prefix);
                    if let Some(ext) = Path::new(&detected).extension() {
                        name.push('.');
                        name.push_str(&ext.to_string_lossy());
                    }
                }

                let total_parts = if spooled_len == 0 {
                    1
                } else {
                    ((spooled_len + RAW_CHUNK_SIZE as u64 - 1) / RAW_CHUNK_SIZE as u64) as usize
                };
                let bytes_sent = stream_preview(
                    &mut spool.file,
                    spooled_len,
                    &transfer_id,
                    &name,
                    in_tmux,
                    &mut terminal_writer,
                )?;

                println!(
                    "Sent '{}' ({} bytes, {} part{}) to iOS Quick Look preview.",
                    name,
                    bytes_sent,
                    total_parts,
                    if total_parts == 1 { "" } else { "s" }
                );
            }
        }
        None => {
            // Piped stdin: spool to temporary file
            let (mut spool, spooled_len, prefix) = spool_to_temp(io::stdin(), MAX_PREVIEW_BYTES)?;
            let name = explicit_name.map(String::from).unwrap_or_else(|| detect_filename(&prefix));

            let total_parts = if spooled_len == 0 {
                1
            } else {
                ((spooled_len + RAW_CHUNK_SIZE as u64 - 1) / RAW_CHUNK_SIZE as u64) as usize
            };
            let bytes_sent = stream_preview(
                &mut spool.file,
                spooled_len,
                &transfer_id,
                &name,
                in_tmux,
                &mut terminal_writer,
            )?;

            println!(
                "Sent '{}' ({} bytes, {} part{}) to iOS Quick Look preview.",
                name,
                bytes_sent,
                total_parts,
                if total_parts == 1 { "" } else { "s" }
            );
        }
    }

    Ok(())
}

pub const AGENT_PREAMBLE_MAGIC: &[u8; 4] = b"FIL1";

pub struct AgentConfig {
    pub port: u16,
    pub token: [u8; 32],
}

/// Parses ~/.filaire/agent: line 1 = port, line 2 = 64 hex chars token
pub fn parse_agent_config(contents: &str) -> Option<AgentConfig> {
    let mut lines = contents.lines();
    let port: u16 = lines.next()?.trim().parse().ok()?;
    if port == 0 {
        return None;
    }
    let hex = lines.next()?.trim();
    if hex.len() != 64 || !hex.bytes().all(|b| b.is_ascii_hexdigit()) {
        return None;
    }
    let mut token = [0u8; 32];
    for (i, byte) in token.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok()?;
    }
    Some(AgentConfig { port, token })
}

pub fn agent_preamble(config: &AgentConfig) -> Vec<u8> {
    let mut out = AGENT_PREAMBLE_MAGIC.to_vec();
    out.extend_from_slice(&config.token);
    out
}

pub fn filaire_dir() -> io::Result<PathBuf> {
    let home = env::var("HOME").map_err(|_| io::Error::new(io::ErrorKind::NotFound, "HOME is not set"))?;
    Ok(PathBuf::from(home).join(".filaire"))
}

pub fn default_agent_socket_path() -> io::Result<PathBuf> {
    Ok(filaire_dir()?.join("agent.sock"))
}

/// Rejects symlinks, paths not owned by `owner_uid`, and any group/other permission bits
#[cfg(unix)]
pub fn ensure_private(path: &Path, owner_uid: u32) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    let fail = |why: &str| Err(io::Error::new(io::ErrorKind::PermissionDenied, format!("{} {}", path.display(), why)));
    if meta.file_type().is_symlink() {
        return fail("is a symlink");
    }
    if meta.uid() != owner_uid {
        return fail("is not owned by you");
    }
    if meta.mode() & 0o077 != 0 {
        return fail("is accessible by other users (expected mode 700/600)");
    }
    Ok(())
}

#[cfg(unix)]
pub fn load_agent_config() -> io::Result<AgentConfig> {
    let dir = filaire_dir()?;
    let owner_uid = fs::metadata(dir.parent().unwrap_or(Path::new("/")))?.uid();
    ensure_private(&dir, owner_uid)?;
    let path = dir.join("agent");
    ensure_private(&path, owner_uid)?;
    let contents = fs::read_to_string(&path)?;
    parse_agent_config(&contents)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, format!("{} is malformed", path.display())))
}

/// Accepts only a plain positive PID greater than 1 (never 0, 1, or negative process-group targets)
pub fn parse_pid(contents: &str) -> Option<u32> {
    let trimmed = contents.trim();
    if trimmed.is_empty() || !trimmed.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let pid: u32 = trimmed.parse().ok()?;
    if pid > 1 { Some(pid) } else { None }
}

pub fn probe_agent(config: &AgentConfig) -> bool {
    if let Ok(mut stream) = TcpStream::connect(("127.0.0.1", config.port)) {
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(500)));
        let _ = stream.set_write_timeout(Some(std::time::Duration::from_millis(500)));
        let mut req = agent_preamble(config);
        req.extend_from_slice(&[0x00, 0x00, 0x00, 0x01, 0x0B]);
        if stream.write_all(&req).is_ok() {
            let mut header = [0u8; 5];
            if stream.read_exact(&mut header).is_ok() {
                return header[4] == 12 || header[4] == 5;
            }
        }
    }
    false
}

#[cfg(unix)]
pub fn probe_unix_socket(path: &str) -> bool {
    if let Ok(mut stream) = UnixStream::connect(path) {
        let _ = stream.set_read_timeout(Some(std::time::Duration::from_millis(500)));
        let _ = stream.set_write_timeout(Some(std::time::Duration::from_millis(500)));
        if stream.write_all(&[0x00, 0x00, 0x00, 0x01, 0x0B]).is_ok() {
            let mut header = [0u8; 5];
            if stream.read_exact(&mut header).is_ok() {
                return header[4] == 12 || header[4] == 5;
            }
        }
    }
    false
}

#[cfg(unix)]
pub fn run_agent_bridge(sock_path: &Path) -> io::Result<()> {
    let pid_file = sock_path.with_extension("pid");
    let _ = fs::write(&pid_file, std::process::id().to_string());
    let _ = fs::remove_file(sock_path);
    let listener = UnixListener::bind(sock_path)?;
    let _ = fs::set_permissions(sock_path, fs::Permissions::from_mode(0o600));

    for stream in listener.incoming() {
        match stream {
            Ok(unix_stream) => {
                std::thread::spawn(move || {
                    let config = match load_agent_config() {
                        Ok(c) => c,
                        Err(_) => return,
                    };
                    let mut tcp_stream = match TcpStream::connect(("127.0.0.1", config.port)) {
                        Ok(s) => s,
                        Err(_) => return,
                    };
                    if tcp_stream.write_all(&agent_preamble(&config)).is_err() {
                        return;
                    }

                    let mut u_read = match unix_stream.try_clone() {
                        Ok(s) => s,
                        Err(_) => return,
                    };
                    let mut u_write = unix_stream;
                    let mut t_read = match tcp_stream.try_clone() {
                        Ok(s) => s,
                        Err(_) => return,
                    };
                    let mut t_write = tcp_stream;

                    let t_shutdown = t_write.try_clone().ok();
                    let u_shutdown = u_write.try_clone().ok();

                    let h1 = std::thread::spawn(move || {
                        let _ = io::copy(&mut u_read, &mut t_write);
                        if let Some(s) = t_shutdown {
                            let _ = s.shutdown(std::net::Shutdown::Write);
                        }
                    });
                    let h2 = std::thread::spawn(move || {
                        let _ = io::copy(&mut t_read, &mut u_write);
                        if let Some(s) = u_shutdown {
                            let _ = s.shutdown(std::net::Shutdown::Write);
                        }
                    });

                    let _ = h1.join();
                    let _ = h2.join();
                });
            }
            Err(_) => break,
        }
    }
    let _ = fs::remove_file(sock_path);
    let _ = fs::remove_file(&pid_file);
    Ok(())
}

pub fn format_status_report(
    in_tmux: bool,
    tmux_env: Option<&str>,
    tty_ok: bool,
    sock_env: Option<&str>,
    is_stdout_term: bool,
    is_stdin_term: bool,
) -> String {
    let mut out = String::new();
    out.push_str("fil status - Remote Environment Diagnosis\n");
    out.push_str("------------------------------------------\n");
    out.push_str(&format!("Version:             fil {}\n", env!("CARGO_PKG_VERSION")));
    out.push_str(&format!("tmux session:        {}\n", if in_tmux { "Active" } else { "None" }));
    if let Some(t) = tmux_env {
        out.push_str(&format!("tmux socket/pane:    {}\n", t));
    }
    out.push_str(&format!("/dev/tty accessible: {}\n", if tty_ok { "Yes" } else { "No (using stdout)" }));
    if let Some(s) = sock_env {
        let exists = std::path::Path::new(s).exists();
        out.push_str(&format!("SSH_AUTH_SOCK:       {} (exists: {})\n", s, exists));
    } else {
        out.push_str("SSH_AUTH_SOCK:       Not set (run 'eval $(fil agent)' to connect)\n");
    }
    out.push_str(&format!("Terminal stdout tty: {}\n", if is_stdout_term { "Yes" } else { "No (piped)" }));
    out.push_str(&format!("Terminal stdin tty:  {}\n", if is_stdin_term { "Yes" } else { "No (piped)" }));
    out
}

pub fn handle_status() -> io::Result<()> {
    let in_tmux = env::var("TMUX").is_ok();
    let tmux_env = env::var("TMUX").ok();
    let tty_ok = OpenOptions::new().write(true).open("/dev/tty").is_ok();
    let sock_env = env::var("SSH_AUTH_SOCK").ok();
    let report = format_status_report(
        in_tmux,
        tmux_env.as_deref(),
        tty_ok,
        sock_env.as_deref(),
        io::stdout().is_terminal(),
        io::stdin().is_terminal(),
    );
    print!("{}", report);
    Ok(())
}

fn print_help() {
    println!(
        r#"fil - Filaire iOS Companion CLI

USAGE:
    cat file.foo | fil             Copy piped stdin to iOS clipboard
    fil copy [FILE]                Copy file or stdin to iOS clipboard
    fil notify <MSG> [-t TITLE]    Send native notification to iOS
    fil open <URL>                 Open URL on iOS Safari
    fil preview [FILE] [-n NAME]   Preview file/stdin in native iOS Quick Look
    eval $(fil agent)              Connect to forwarded Filaire SSH Agent (Touch ID / Face ID)
    fil agent [-s SOCK] [-k] [-f]  Manage SSH Agent forwarding bridge
    fil status                     Diagnose tmux, tty, and agent environment
    fil [TEXT...]                  Copy text arguments or file to iOS clipboard
    fil --version                  Show CLI version
    fil --help                     Show this help message

EXAMPLES:
    # Copy file or pipeline to iOS clipboard
    cat build.log | fil
    fil copy ~/.ssh/id_ed25519.pub
    fil "Hello from remote server!"

    # Send iOS notification on command completion
    cargo build && fil notify "Build succeeded!" -t "Cargo"
    fil notify "Database migration complete"

    # Open link in iOS Safari
    fil open "https://github.com/JeremyOT/filaire"

    # Preview image, PDF, audio, video, or markdown in iOS Quick Look
    fil preview chart.png
    fil preview report.pdf
    git diff | fil preview --name diff.patch

    # Connect remote environment to Filaire biometric SSH agent
    eval $(fil agent)
    ssh-add -l
"#
    );
}

fn main() -> io::Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();

    if args.is_empty() {
        // If stdin has data piped into it, read stdin and copy to clipboard
        if !io::stdin().is_terminal() {
            let mut buffer = Vec::new();
            io::stdin().read_to_end(&mut buffer)?;
            copy_to_clipboard(&buffer)?;
            return Ok(());
        } else {
            print_help();
            return Ok(());
        }
    }

    match args[0].as_str() {
        "--help" | "-h" | "help" => {
            print_help();
            Ok(())
        }
        "--version" | "-v" | "version" => {
            println!("fil {}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        "status" => handle_status(),
        "copy" | "cp" => {
            if args.len() > 1 {
                if args.len() == 2 && std::path::Path::new(&args[1]).is_file() {
                    let content = fs::read(&args[1])?;
                    copy_to_clipboard(&content)?;
                } else {
                    let text = args[1..].join(" ");
                    copy_to_clipboard(text.as_bytes())?;
                }
            } else {
                let mut buffer = Vec::new();
                io::stdin().read_to_end(&mut buffer)?;
                copy_to_clipboard(&buffer)?;
            }
            Ok(())
        }
        "notify" | "n" => {
            let (title, body) = parse_notify_args(&args[1..]);
            send_notification(&title, &body)?;
            Ok(())
        }
        "open" => {
            if args.len() > 1 {
                let url = &args[1];
                open_url(url)?;
            } else {
                eprintln!("Error: fil open requires a URL argument.");
                std::process::exit(1);
            }
            Ok(())
        }
        "preview" | "view" | "p" | "prev" => {
            let mut file_path: Option<String> = None;
            let mut custom_name: Option<String> = None;
            let mut iter = args[1..].iter().peekable();

            while let Some(arg) = iter.next() {
                if (arg == "-n" || arg == "--name") && iter.peek().is_some() {
                    custom_name = Some(iter.next().unwrap().clone());
                } else if !arg.starts_with('-') && file_path.is_none() {
                    file_path = Some(arg.clone());
                }
            }

            preview_file(file_path.as_deref(), custom_name.as_deref())?;
            Ok(())
        }
        "agent" => {
            let mut sock_path = default_agent_socket_path()?;
            let mut foreground = false;
            let mut kill = false;
            let mut iter = args[1..].iter().peekable();

            while let Some(arg) = iter.next() {
                if (arg == "-s" || arg == "--socket") && iter.peek().is_some() {
                    sock_path = PathBuf::from(iter.next().unwrap());
                } else if arg == "-f" || arg == "--foreground" {
                    foreground = true;
                } else if arg == "-k" || arg == "--kill" {
                    kill = true;
                }
            }

            let pid_file = sock_path.with_extension("pid");
            if kill {
                if let Ok(pid_str) = fs::read_to_string(&pid_file) {
                    if let Some(pid) = parse_pid(&pid_str) {
                        let _ = Command::new("kill").args(["-TERM", &pid.to_string()]).status();
                    }
                }
                let _ = fs::remove_file(&pid_file);
                let _ = fs::remove_file(&sock_path);
                println!("Filaire SSH Agent stopped (removed {}).", sock_path.display());
                return Ok(());
            }

            #[cfg(unix)]
            {
                let config = match load_agent_config() {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("Error: {}. Enable 'SSH Agent Forwarding' for this host in Filaire and reconnect.", e);
                        std::process::exit(1);
                    }
                };

                if foreground {
                    if let Some(parent) = sock_path.parent() {
                        if !parent.exists() {
                            fs::create_dir_all(parent)?;
                            fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
                        }
                        let owner_uid = fs::metadata(parent.parent().unwrap_or(Path::new("/")))?.uid();
                        ensure_private(parent, owner_uid)?;
                    }
                    if sock_path.as_os_str().len() > 100 {
                        eprintln!("Warning: Unix domain socket paths are limited to ~104 characters (current: {}). Use -s to specify a shorter socket path if binding fails.", sock_path.as_os_str().len());
                    }
                    println!("Filaire SSH Agent proxy listening on {}", sock_path.display());
                    run_agent_bridge(&sock_path)?;
                    return Ok(());
                }

                let sock_str = sock_path.to_str().unwrap_or("");
                // If socket already active and working, just print export
                if probe_unix_socket(sock_str) {
                    println!("SSH_AUTH_SOCK=\"{}\"; export SSH_AUTH_SOCK;", sock_path.display());
                    return Ok(());
                }

                // Check TCP agent forward port
                if !probe_agent(&config) {
                    eprintln!("Warning: Filaire agent port {} is not currently responding on 127.0.0.1. Ensure 'Enable SSH Agent Forwarding' is active in host settings.", config.port);
                }

                let _ = fs::remove_file(&pid_file);
                let _ = fs::remove_file(&sock_path);
                if let Ok(exe) = env::current_exe() {
                    let _ = Command::new(exe)
                        .args(["agent", "--foreground", "-s", sock_str])
                        .stdin(std::process::Stdio::null())
                        .stdout(std::process::Stdio::null())
                        .stderr(std::process::Stdio::null())
                        .spawn();
                    std::thread::sleep(std::time::Duration::from_millis(150));
                }

                if io::stdout().is_terminal() {
                    eprintln!("# Tip: Run eval $(fil agent) to export SSH_AUTH_SOCK into your current shell");
                }
                println!("SSH_AUTH_SOCK=\"{}\"; export SSH_AUTH_SOCK;", sock_path.display());
            }
            #[cfg(not(unix))]
            {
                eprintln!("fil agent requires a Unix platform.");
            }
            Ok(())
        }
        _ => {
            // Check if first arg is an existing file path
            if args.len() == 1 && std::path::Path::new(&args[0]).is_file() {
                let content = fs::read(&args[0])?;
                copy_to_clipboard(&content)?;
            } else {
                // Treat remaining arguments as plain text to copy
                let text = args.join(" ");
                copy_to_clipboard(text.as_bytes())?;
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_base64_encode() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(b"f"), "Zg==");
        assert_eq!(base64_encode(b"fo"), "Zm8=");
        assert_eq!(base64_encode(b"foo"), "Zm9v");
        assert_eq!(base64_encode(b"foob"), "Zm9vYg==");
        assert_eq!(base64_encode(b"fooba"), "Zm9vYmE=");
        assert_eq!(base64_encode(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_encode(b"Hello, iOS!"), "SGVsbG8sIGlPUyE=");
    }

    #[test]
    fn test_osc52_formatting() {
        let osc = format_osc52(b"Hello");
        assert_eq!(osc, "\x1b]52;c;SGVsbG8=\x07");
    }

    #[test]
    fn test_osc777_formatting() {
        let osc = format_osc777("Cargo", "Build complete");
        assert_eq!(osc, "\x1b]777;notify;Cargo;Build complete\x07");
    }

    #[test]
    fn test_parse_notify_args() {
        // No args: default
        let (title, body) = parse_notify_args(&[] as &[&str]);
        assert_eq!(title, "Filaire");
        assert_eq!(body, "Task completed");

        // 1 arg: message only
        let (title, body) = parse_notify_args(&["Build done"]);
        assert_eq!(title, "Filaire");
        assert_eq!(body, "Build done");

        // 2 args: title and body
        let (title, body) = parse_notify_args(&["Cargo", "Build complete"]);
        assert_eq!(title, "Cargo");
        assert_eq!(body, "Build complete");

        // -t flag with body
        let (title, body) = parse_notify_args(&["Build complete", "-t", "Cargo"]);
        assert_eq!(title, "Cargo");
        assert_eq!(body, "Build complete");

        // -t flag before body
        let (title, body) = parse_notify_args(&["-t", "Cargo", "Build complete"]);
        assert_eq!(title, "Cargo");
        assert_eq!(body, "Build complete");

        // -t flag only
        let (title, body) = parse_notify_args(&["-t", "Cargo"]);
        assert_eq!(title, "Cargo");
        assert_eq!(body, "Task completed");

        // >2 positional args without flag
        let (title, body) = parse_notify_args(&["Database", "backup", "finished", "now"]);
        assert_eq!(title, "Filaire");
        assert_eq!(body, "Database backup finished now");
    }

    #[test]
    fn test_osc_open_formatting() {
        let osc = format_osc_open("https://example.com");
        assert_eq!(osc, "\x1b]5100;open;https://example.com\x07");
    }

    #[test]
    fn test_osc_preview_chunk_formatting() {
        let osc = format_osc_preview_chunk("tid1", "test.png", 1, 2, "ABCD");
        assert_eq!(osc, "\x1b]5101;preview;id=tid1;name=test.png;part=1;total=2;ABCD\x07");

        // Semicolon in filename should be sanitized
        let osc_sanitized = format_osc_preview_chunk("tid2", "foo;bar.png", 1, 1, "XYZ");
        assert_eq!(osc_sanitized, "\x1b]5101;preview;id=tid2;name=foo_bar.png;part=1;total=1;XYZ\x07");
    }

    #[test]
    fn test_detect_filename() {
        assert_eq!(detect_filename(b"\x89PNG\r\n\x1a\n..."), "preview.png");
        assert_eq!(detect_filename(b"\xff\xd8\xff\xe0..."), "preview.jpg");
        assert_eq!(detect_filename(b"GIF89a..."), "preview.gif");
        assert_eq!(detect_filename(b"%PDF-1.4..."), "preview.pdf");
        assert_eq!(detect_filename(b"PK\x03\x04..."), "preview.zip");
        assert_eq!(detect_filename(b"RIFF\x00\x00\x00\x00WEBP..."), "preview.webp");
        assert_eq!(detect_filename(b"RIFF\x00\x00\x00\x00WAVEfmt "), "preview.wav");
        assert_eq!(detect_filename(b"\x00\x00\x00\x20ftypmp42..."), "preview.mp4");
        assert_eq!(detect_filename(b"ID3\x03\x00\x00..."), "preview.mp3");
        assert_eq!(detect_filename(b"{\"key\": \"val\"}"), "preview.json");
        assert_eq!(detect_filename(b"<svg xmlns=\"...\"></svg>"), "preview.svg");
        assert_eq!(detect_filename(b"<!DOCTYPE html><html></html>"), "preview.html");
        assert_eq!(detect_filename(b"\x1f\x8b\x08..."), "preview.gz");
        assert_eq!(detect_filename(b"BZh91AY..."), "preview.bz2");
        assert_eq!(detect_filename(b"---\nservice: test\nversion: 1"), "preview.yaml");
        assert_eq!(detect_filename(b"id,name,value\n1,alpha,100\n"), "preview.csv");
        assert_eq!(detect_filename(b"id\tname\tvalue\n1\talpha\t100\n"), "preview.tsv");
        assert_eq!(detect_filename(b"Hello world"), "preview.txt");
    }

    #[test]
    fn test_wrap_tmux_dcs() {
        let raw = "\x1b]52;c;SGVsbG8=\x07";
        let wrapped = wrap_tmux_dcs(raw);
        assert_eq!(wrapped, "\x1bPtmux;\x1b\x1b]52;c;SGVsbG8=\x07\x1b\\");
    }

    #[test]
    fn test_default_agent_socket_path() {
        env::set_var("HOME", "/tmp/fil-test-home");
        let path = default_agent_socket_path().expect("default_agent_socket_path should succeed");
        assert!(path.to_str().unwrap().ends_with(".filaire/agent.sock"));
    }

    #[test]
    fn test_parse_agent_config() {
        let valid = format!("40123\n{}\n", "ab".repeat(32));
        let config = parse_agent_config(&valid).expect("Valid config should parse");
        assert_eq!(config.port, 40123);
        assert_eq!(config.token, [0xabu8; 32]);

        // None cases
        assert!(parse_agent_config(&format!("0\n{}\n", "ab".repeat(32))).is_none());
        assert!(parse_agent_config(&format!("70000\n{}\n", "ab".repeat(32))).is_none());
        assert!(parse_agent_config(&format!("40123\n{}\n", "a".repeat(63))).is_none());
        assert!(parse_agent_config(&format!("40123\n{}\n", "z".repeat(64))).is_none());
        assert!(parse_agent_config(&format!("40123\n+f{}\n", "ab".repeat(31))).is_none());
        assert!(parse_agent_config("40123\n").is_none());
    }

    #[test]
    fn test_agent_preamble() {
        let config = AgentConfig {
            port: 40123,
            token: [0xabu8; 32],
        };
        let preamble = agent_preamble(&config);
        assert_eq!(preamble.len(), 36);
        assert_eq!(&preamble[0..4], b"FIL1");
        assert_eq!(&preamble[4..], &[0xabu8; 32]);
    }

    #[test]
    fn test_parse_pid() {
        assert_eq!(parse_pid("123\n"), Some(123));
        assert_eq!(parse_pid("-1"), None);
        assert_eq!(parse_pid("0"), None);
        assert_eq!(parse_pid("1"), None);
        assert_eq!(parse_pid(""), None);
        assert_eq!(parse_pid("12a"), None);
        assert_eq!(parse_pid(" -5"), None);
    }

    #[cfg(unix)]
    #[test]
    fn test_ensure_private() -> io::Result<()> {
        let dir = env::temp_dir().join(format!("fil-test-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir)?;

        let owner_uid = fs::metadata(&dir)?.uid();

        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
        assert!(ensure_private(&dir, owner_uid).is_ok());

        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755))?;
        assert!(ensure_private(&dir, owner_uid).is_err());

        // Test symlink
        let link = env::temp_dir().join(format!("fil-test-link-{}", std::process::id()));
        let _ = fs::remove_file(&link);
        std::os::unix::fs::symlink(&dir, &link)?;
        assert!(ensure_private(&link, owner_uid).is_err());

        let _ = fs::remove_file(&link);
        let _ = fs::remove_dir_all(&dir);
        Ok(())
    }

    #[test]
    fn test_version_string() {
        assert_eq!(env!("CARGO_PKG_VERSION"), "0.1.0");
    }

    #[test]
    fn test_status_report() {
        let report = format_status_report(true, Some("/tmp/tmux-1000/default,1234,0"), true, Some("/tmp/agent.sock"), true, true);
        assert!(report.contains("tmux session:        Active"));
        assert!(report.contains("/tmp/tmux-1000/default,1234,0"));
        assert!(report.contains("/dev/tty accessible: Yes"));
        assert!(report.contains("SSH_AUTH_SOCK:       /tmp/agent.sock"));
    }

    #[test]
    fn test_streaming_preview_matches_whole_buffer_encoding() {
        let test_lengths = [0, 1, 2, 3, 6143, 6144, 6145, 12288, 20000];
        for &len in &test_lengths {
            let data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();

            // Whole-buffer baseline
            let b64 = base64_encode(&data);
            let chunk_size = 8192;
            let expected_total_parts = if b64.is_empty() { 1 } else { (b64.len() + chunk_size - 1) / chunk_size };
            let mut expected_chunks = Vec::new();
            for p in 0..expected_total_parts {
                let start = p * chunk_size;
                let end = ((p + 1) * chunk_size).min(b64.len());
                let chunk = if b64.is_empty() { "" } else { &b64[start..end] };
                expected_chunks.push(chunk.to_string());
            }

            // Streaming output
            let mut streamed_output = Vec::new();
            let cursor = io::Cursor::new(&data);
            let sent = stream_preview(cursor, len as u64, "tid", "test.bin", false, &mut streamed_output)
                .expect("stream_preview should succeed");
            assert_eq!(sent, len as u64);

            // Parse emitted chunks from streamed_output
            let out_str = std::str::from_utf8(&streamed_output).expect("valid utf8");
            let mut streamed_chunks = Vec::new();
            for line in out_str.split('\x07') {
                if line.is_empty() {
                    continue;
                }
                assert!(line.starts_with("\x1b]5101;preview;id=tid;name=test.bin;"));
                let parts: Vec<&str> = line.split(';').collect();
                let part_str = parts[4]; // part=X
                let total_str = parts[5]; // total=Y
                let chunk_data = parts[6]; // base64 chunk
                assert_eq!(total_str, format!("total={}", expected_total_parts));
                assert_eq!(part_str, format!("part={}", streamed_chunks.len() + 1));
                streamed_chunks.push(chunk_data.to_string());
            }

            assert_eq!(streamed_chunks.len(), expected_total_parts);
            assert_eq!(
                streamed_chunks, expected_chunks,
                "Chunks must match whole-buffer encoding exactly for len={}",
                len
            );
        }
    }

    struct ShortReader<R> {
        inner: R,
        step: usize,
    }

    impl<R: Read> Read for ShortReader<R> {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.step += 1;
            if self.step % 7 == 0 {
                return Err(io::Error::new(io::ErrorKind::Interrupted, "simulated interrupt"));
            }
            let max_to_read = (self.step % 5) + 1;
            let limit = buf.len().min(max_to_read);
            self.inner.read(&mut buf[..limit])
        }
    }

    #[test]
    fn test_stream_preview_short_reads_and_interruptions() {
        let len = 20000;
        let data: Vec<u8> = (0..len).map(|i| (i % 251) as u8).collect();
        let expected_b64 = base64_encode(&data);

        let reader = ShortReader {
            inner: io::Cursor::new(&data),
            step: 0,
        };

        let mut output = Vec::new();
        let sent = stream_preview(reader, len as u64, "tid", "data.bin", false, &mut output)
            .expect("stream_preview with short reads and interrupts should succeed");
        assert_eq!(sent, len as u64);

        // Concatenate base64 chunks from output and compare to expected_b64
        let out_str = std::str::from_utf8(&output).expect("valid utf8");
        let mut reconstructed_b64 = String::new();
        for line in out_str.split('\x07') {
            if line.is_empty() {
                continue;
            }
            let parts: Vec<&str> = line.split(';').collect();
            reconstructed_b64.push_str(parts[6]);
        }

        assert_eq!(reconstructed_b64, expected_b64);
    }

    #[test]
    fn test_stream_preview_truncated_input_returns_unexpected_eof() {
        let data = vec![0x42u8; 1000];
        let cursor = io::Cursor::new(data);
        let mut output = Vec::new();
        // Claim 2000 bytes when only 1000 are present
        let res = stream_preview(cursor, 2000, "tid", "trunc.bin", false, &mut output);
        match res {
            Err(e) => assert_eq!(e.kind(), io::ErrorKind::UnexpectedEof),
            Ok(_) => panic!("Expected UnexpectedEof on truncated input"),
        }
    }

    struct FailingWriter {
        written: usize,
        fail_after: usize,
        fail_on_flush: bool,
    }

    impl Write for FailingWriter {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            if self.written + buf.len() > self.fail_after {
                return Err(io::Error::new(io::ErrorKind::BrokenPipe, "simulated write failure"));
            }
            self.written += buf.len();
            Ok(buf.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            if self.fail_on_flush {
                Err(io::Error::new(io::ErrorKind::Other, "simulated flush failure"))
            } else {
                Ok(())
            }
        }
    }

    #[test]
    fn test_stream_preview_failing_writer_propagates_error() {
        let data = vec![0x55u8; 10000];
        let cursor = io::Cursor::new(data);
        let writer = FailingWriter {
            written: 0,
            fail_after: 500,
            fail_on_flush: false,
        };

        let res = stream_preview(cursor, 10000, "tid", "fail.bin", false, writer);
        match res {
            Err(e) => assert_eq!(e.kind(), io::ErrorKind::BrokenPipe),
            Ok(_) => panic!("Expected BrokenPipe error on failing writer"),
        }
    }

    #[test]
    fn test_stream_preview_failing_flush_propagates_error() {
        let data = vec![0x55u8; 1000];
        let cursor = io::Cursor::new(data);
        let writer = FailingWriter {
            written: 0,
            fail_after: usize::MAX,
            fail_on_flush: true,
        };

        let res = stream_preview(cursor, 1000, "tid", "flush_fail.bin", false, writer);
        match res {
            Err(e) => assert_eq!(e.to_string(), "simulated flush failure"),
            Ok(_) => panic!("Expected error on failing flush"),
        }
    }

    #[test]
    fn test_stream_preview_over_limit_fails_before_emission() {
        let cursor = io::Cursor::new(&b""[..]);
        let mut output = Vec::new();
        let res = stream_preview(
            cursor,
            MAX_PREVIEW_BYTES + 1,
            "tid",
            "big.bin",
            false,
            &mut output,
        );
        match res {
            Err(e) => assert_eq!(e.kind(), io::ErrorKind::InvalidInput),
            Ok(_) => panic!("Expected InvalidInput error for over-limit input"),
        }
        assert!(output.is_empty(), "No bytes should be emitted if over limit");
    }

    #[test]
    fn test_temp_file_guard_exclusive_and_cleanup_on_drop() {
        let path = {
            let guard = TempFileGuard::new().expect("TempFileGuard::new should succeed");
            assert!(guard.path.exists());
            #[cfg(unix)]
            {
                let meta = fs::metadata(&guard.path).expect("metadata should succeed");
                assert_eq!(meta.permissions().mode() & 0o777, 0o600);
            }
            guard.path.clone()
        };
        // After guard is dropped, file must be removed
        assert!(!path.exists(), "Temporary file must be deleted when guard drops");
    }

    #[test]
    fn test_spool_to_temp_exact_and_over_limit() {
        let exact_data = vec![0xAAu8; 1000];
        let cursor = io::Cursor::new(&exact_data);
        let (mut guard, spooled_len, prefix) = spool_to_temp(cursor, 1000).expect("Exact limit should succeed");
        assert_eq!(spooled_len, 1000);
        assert_eq!(prefix, &exact_data[..prefix.len()]);
        assert!(guard.path.exists());

        // Rewind and verify file content
        let mut read_back = Vec::new();
        guard.file.read_to_end(&mut read_back).expect("read_to_end should succeed");
        assert_eq!(read_back, exact_data);
        let path = guard.path.clone();
        drop(guard);
        assert!(!path.exists());

        // Over limit (1001 bytes with 1000 max)
        let over_data = vec![0xBBu8; 1001];
        let cursor_over = io::Cursor::new(&over_data);
        let res = spool_to_temp(cursor_over, 1000);
        match res {
            Err(e) => assert_eq!(e.kind(), io::ErrorKind::InvalidInput),
            Ok(_) => panic!("Expected InvalidInput for over-limit spooling"),
        }
    }

    #[test]
    fn test_write_osc_sequence_tmux_and_plain() {
        let mut plain = Vec::new();
        write_osc_sequence(&mut plain, "\x1b]777;notify;T;B\x07", false).expect("write plain");
        assert_eq!(std::str::from_utf8(&plain).unwrap(), "\x1b]777;notify;T;B\x07");

        let mut tmux = Vec::new();
        write_osc_sequence(&mut tmux, "\x1b]777;notify;T;B\x07", true).expect("write tmux");
        assert_eq!(
            std::str::from_utf8(&tmux).unwrap(),
            "\x1bPtmux;\x1b\x1b]777;notify;T;B\x07\x1b\\"
        );

        // OSC 52 inside tmux should emit both DCS and raw sequence
        let mut tmux_osc52 = Vec::new();
        write_osc_sequence(&mut tmux_osc52, "\x1b]52;c;SGVsbG8=\x07", true).expect("write tmux osc52");
        let expected = format!(
            "{}{}",
            wrap_tmux_dcs("\x1b]52;c;SGVsbG8=\x07"),
            "\x1b]52;c;SGVsbG8=\x07"
        );
        assert_eq!(std::str::from_utf8(&tmux_osc52).unwrap(), expected);
    }
}
