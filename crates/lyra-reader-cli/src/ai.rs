//! `lyra-reader-cli ai probe`: a manual smoke probe for one real OpenAI-compatible endpoint.
//!
//! This is deliberately not part of the automated gate. It sends the operator's prompt (and
//! optional PNG) to the endpoint they name, through the same request builder, transport and SSE
//! decoder in `lyra-reader-ai` that the app uses. That is what makes the result evidence about
//! the real client rather than about a second HTTP implementation written only for the CLI.
//!
//! The command never runs from tests or CI, never logs the API key, and refuses a non-loopback
//! host until `--yes-remote` is passed.

use std::io::{Cursor, Write};
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use lyra_reader_ai::chat::{ReasoningEncoding, ReasoningMode};
use lyra_reader_ai::openai::{
    CancellationToken, ClientConfig, RequestSpec, RunEvent, StreamDiagnostics, TokenUsage,
    Transport, build_request_spec, default_transport, run_plan_with_transport,
};
use lyra_reader_ai::{
    AiError, ChatImage, ChatPlan, ChatSettings, EndpointInfo, MAX_REGION_IMAGE_BYTES,
    PromptPlanRequest, build_prompt_plan, inspect_base_url,
};

/// Exit code for local usage/settings refusals. `64` matches the CLI's unknown-subcommand code.
const EXIT_USAGE: u8 = 64;
/// Exit code for a transport, HTTP or stream failure.
const EXIT_REQUEST_FAILED: u8 = 1;
/// A probe is a bounded manual smoke test, so it sends a small default rather than the provider's
/// (possibly very large) default completion budget.
const DEFAULT_MAX_TOKENS: u32 = 256;
/// The app's default temperature. Keeping it here means the probe exercises the same body shape.
const DEFAULT_TEMPERATURE: f32 = 0.2;

const AI_USAGE: &str = r#"lyra-reader-cli ai probe — manual real-endpoint check

Sends one prompt (and optionally one PNG) to the OpenAI-compatible endpoint you name, through
the same request builder, transport and SSE parser as the LyraReader app. This is a manual
validation tool, not a test: never call it from tests or CI. It sends your prompt and picture
to the endpoint you name.

Usage:
  lyra-reader-cli ai probe --base-url URL --model MODEL --prompt TEXT [options]

Required:
  --base-url URL       base URL without /chat/completions (http://127.0.0.1:8080/v1)
  --model MODEL        provider model id (mlx-community/Qwen3.8-27B-8bit)
  --prompt TEXT        the prompt to send

Options:
  --api-key KEY        API key; otherwise LYRA_READER_AI_API_KEY, then OPENAI_API_KEY.
                       The key is never printed. A local server that ignores authentication
                       still needs a non-empty value; use a distinct placeholder such as
                       --api-key sk-local-placeholder for such a server.
  --image PATH.png     attach one PNG as an image_url data URL (PNG only; sent unchanged)
  --max-tokens N       completion budget (default 256; 1..32768)
  --stream             stream the answer (default)
  --no-stream          ask for one complete JSON response instead
  --yes-remote         allow a non-loopback endpoint; your prompt leaves this Mac

Safety:
  Loopback hosts (localhost, 127.0.0.0/8, ::1) run without --yes-remote. Any other host is
  refused until --yes-remote is passed. The request preview prints the endpoint, model,
  character count, image size, body size and redacted headers before anything is sent.
  A CI environment is refused outright.

Examples:
  lyra-reader-cli ai probe --base-url http://127.0.0.1:8080/v1 \
      --model mlx-community/Qwen3.8-27B-8bit --api-key sk-local-placeholder \
      --prompt "Reply with one short sentence about PDF text layers."

  lyra-reader-cli ai probe --base-url http://127.0.0.1:8080/v1 \
      --model mlx-community/Qwen3.8-27B-8bit --api-key sk-local-placeholder \
      --image build/evidence/region-marquee.png --prompt "Describe this picture."
"#;

#[derive(Clone)]
struct ProbeArgs {
    base_url: String,
    model: String,
    api_key: Option<String>,
    prompt: String,
    image: Option<PathBuf>,
    stream: bool,
    max_tokens: Option<u32>,
    yes_remote: bool,
}

/// A validated probe ready to preview and send. The key is kept only long enough to build the
/// request spec and run the request; it is never printed and is redacted from errors by the
/// client.
struct PreparedProbe {
    plan: ChatPlan,
    spec: RequestSpec,
    key: String,
    image: Option<ChatImage>,
}

pub(crate) fn run(args: &[String]) -> ExitCode {
    match args.first().map(String::as_str) {
        None | Some("-h" | "--help" | "help") => {
            print!("{AI_USAGE}");
            ExitCode::SUCCESS
        }
        Some("probe") => run_probe(&args[1..]),
        Some(other) => {
            eprintln!("unknown ai command: {other}\n");
            eprint!("{AI_USAGE}");
            ExitCode::from(EXIT_USAGE)
        }
    }
}

fn run_probe(args: &[String]) -> ExitCode {
    if args.iter().any(|arg| arg == "-h" || arg == "--help") {
        print!("{AI_USAGE}");
        return ExitCode::SUCCESS;
    }
    if std::env::var_os("CI").is_some() {
        eprintln!(
            "error: refusing to run the manual endpoint probe in CI; this tool sends a prompt to a real server and is not a test."
        );
        return ExitCode::from(EXIT_USAGE);
    }
    let args = match parse_args(args) {
        Ok(args) => args,
        Err(message) => {
            eprintln!("error: {message}");
            eprintln!();
            eprint!("{AI_USAGE}");
            return ExitCode::from(EXIT_USAGE);
        }
    };
    let prepared = match prepare(&args) {
        Ok(prepared) => prepared,
        Err(message) => {
            eprintln!("error: {message}");
            return ExitCode::from(EXIT_USAGE);
        }
    };

    let mut stderr = std::io::stderr();
    let mut stdout = std::io::stdout();
    if let Err(error) = write_preview(
        &mut stderr,
        &prepared.plan,
        &prepared.spec,
        args.prompt.chars().count(),
        prepared.image.as_ref(),
    ) {
        eprintln!("error: cannot write the request preview: {error}");
        return ExitCode::from(EXIT_REQUEST_FAILED);
    }

    let transport = match default_transport(&prepared.plan.endpoint, ClientConfig::default()) {
        Ok(transport) => transport,
        Err(error) => {
            eprintln!("error: {error}");
            return ExitCode::from(EXIT_REQUEST_FAILED);
        }
    };

    match execute(
        &prepared.plan,
        &prepared.key,
        transport.as_ref(),
        &mut stdout,
        &mut stderr,
    ) {
        Ok(outcome) => {
            let _ = stdout.flush();
            // Keep the summary on its own line even when the model's last delta did not end in
            // one; the streamed text itself is not altered.
            if outcome.answer_characters > 0 {
                let _ = writeln!(stdout);
            }
            let _ = writeln!(stdout, "{}", summary_line(&prepared.plan, &outcome));
            let _ = stdout.flush();
            if outcome.answer_characters == 0
                && let Some(diagnostics) = &outcome.diagnostics
            {
                let _ = writeln!(
                    stderr,
                    "note: no answer text; http={} frames={} content_frames={} content_shape={} finish_reason={}",
                    diagnostics.http_status,
                    diagnostics.frames,
                    diagnostics.content_frames,
                    diagnostics.content_shape,
                    diagnostics.finish_reason.as_deref().unwrap_or("none")
                );
            }
            ExitCode::SUCCESS
        }
        Err(error) => {
            let _ = stdout.flush();
            // `run_plan_with_transport` already redacted the key. `Display` is the same message
            // the app's panel receives across the FFI boundary.
            eprintln!("error: {error}");
            ExitCode::from(EXIT_REQUEST_FAILED)
        }
    }
}

fn parse_args(args: &[String]) -> Result<ProbeArgs, String> {
    let (positional, options) = crate::parse(args);
    if let Some(extra) = positional.first() {
        return Err(format!(
            "unexpected argument {extra:?}; `ai probe` takes options only"
        ));
    }
    if options.iter().any(|(name, _)| name == "--stream")
        && options.iter().any(|(name, _)| name == "--no-stream")
    {
        return Err("--stream and --no-stream cannot be combined".to_string());
    }

    let required = |name: &str| -> Result<String, String> {
        crate::opt(&options, &[name])
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(str::to_string)
            .ok_or_else(|| format!("missing {name}; see `lyra-reader-cli ai probe --help`"))
    };

    let prompt = crate::opt(&options, &["--prompt"])
        .filter(|value| !value.trim().is_empty())
        .map(str::to_string)
        .ok_or_else(|| "missing --prompt; see `lyra-reader-cli ai probe --help`".to_string())?;
    let api_key = match crate::opt(&options, &["--api-key"]) {
        Some(value) if value.trim().is_empty() => {
            return Err("--api-key must not be empty".to_string());
        }
        Some(value) => Some(value.trim().to_string()),
        None => environment_key(),
    };
    let max_tokens = match crate::opt(&options, &["--max-tokens"]) {
        Some(value) => Some(
            value
                .parse::<u32>()
                .map_err(|_| format!("--max-tokens must be a number, got {value:?}"))?,
        ),
        None => Some(DEFAULT_MAX_TOKENS),
    };
    let image = match crate::opt(&options, &["--image"]) {
        Some(value) if value.trim().is_empty() => {
            return Err("--image needs a path to a PNG".to_string());
        }
        Some(value) => Some(PathBuf::from(value)),
        None => None,
    };

    Ok(ProbeArgs {
        base_url: required("--base-url")?,
        model: required("--model")?,
        api_key,
        prompt,
        image,
        stream: !options.iter().any(|(name, _)| name == "--no-stream"),
        max_tokens,
        yes_remote: options.iter().any(|(name, _)| name == "--yes-remote"),
    })
}

/// The key precedence is explicit flag, then the environment variable this repository's
/// developer tools use, then the conventional OpenAI variable. An empty value is not a key.
fn environment_key() -> Option<String> {
    for name in ["LYRA_READER_AI_API_KEY", "OPENAI_API_KEY"] {
        if let Ok(value) = std::env::var(name) {
            let value = value.trim();
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }
    None
}

fn prepare(args: &ProbeArgs) -> Result<PreparedProbe, String> {
    let endpoint = inspect_base_url(&args.base_url).map_err(|error| error.to_string())?;
    refuse_non_loopback(&endpoint, args.yes_remote)?;
    let image = match &args.image {
        Some(path) => Some(load_png(path)?),
        None => None,
    };
    let plan = plan_for(args, image.clone()).map_err(|error| error.to_string())?;
    let key = args.api_key.clone().unwrap_or_default();
    let spec =
        build_request_spec(&plan, &plan.parts[0], &key).map_err(|error| error.to_string())?;
    Ok(PreparedProbe {
        plan,
        spec,
        key,
        image,
    })
}

/// Safety gate: only loopback may receive a prompt without an explicit remote opt-in.
fn refuse_non_loopback(endpoint: &EndpointInfo, yes_remote: bool) -> Result<(), String> {
    if endpoint.is_local || yes_remote {
        return Ok(());
    }
    Err(format!(
        "refusing to send to non-loopback endpoint {} (host {}): pass --yes-remote to confirm that this prompt and picture leave this Mac",
        endpoint.endpoint, endpoint.host
    ))
}

fn plan_for(args: &ProbeArgs, image: Option<ChatImage>) -> Result<ChatPlan, AiError> {
    build_prompt_plan(PromptPlanRequest {
        prompt: args.prompt.clone(),
        image,
        stream: args.stream,
        settings: ChatSettings {
            base_url: args.base_url.clone(),
            model: args.model.clone(),
            temperature: Some(DEFAULT_TEMPERATURE),
            max_tokens: args.max_tokens,
            // The probe sends the plain OpenAI-compatible shape: no vendor reasoning extension
            // that a local server might reject for reasons unrelated to the protocol under test.
            reasoning_mode: ReasoningMode::Default,
            reasoning_encoding: ReasoningEncoding::None,
        },
    })
}

/// Read one PNG unchanged and learn its pixel size. No re-encoding: the bytes in the data URL are
/// exactly the bytes on disk.
fn load_png(path: &Path) -> Result<ChatImage, String> {
    let png = std::fs::read(path)
        .map_err(|error| format!("cannot read image {}: {error}", path.display()))?;
    if png.is_empty() {
        return Err(format!("image {} is empty", path.display()));
    }
    if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(format!(
            "{} is not a PNG file; `ai probe` accepts PNG only",
            path.display()
        ));
    }
    if png.len() > MAX_REGION_IMAGE_BYTES {
        return Err(format!(
            "image {} is {} bytes, over the {} MiB limit",
            path.display(),
            png.len(),
            MAX_REGION_IMAGE_BYTES / (1024 * 1024)
        ));
    }
    let reader = image::ImageReader::new(Cursor::new(&png))
        .with_guessed_format()
        .map_err(|error| format!("cannot inspect image {}: {error}", path.display()))?;
    let (width_px, height_px) = reader
        .into_dimensions()
        .map_err(|error| format!("cannot read the size of {}: {error}", path.display()))?;
    Ok(ChatImage {
        width_px,
        height_px,
        png,
    })
}

fn write_preview(
    sink: &mut dyn Write,
    plan: &ChatPlan,
    spec: &RequestSpec,
    prompt_characters: usize,
    image: Option<&ChatImage>,
) -> std::io::Result<()> {
    writeln!(
        sink,
        "==> manual endpoint probe: request preview (nothing has been sent yet)"
    )?;
    writeln!(sink, "  endpoint : {}", plan.endpoint)?;
    writeln!(sink, "  model    : {}", plan.model)?;
    writeln!(
        sink,
        "  prompt   : {prompt_characters} characters (system + prompt: {})",
        plan.parts[0].request_characters
    )?;
    match image {
        Some(image) => writeln!(
            sink,
            "  image    : yes — {} bytes, {}x{} px, sent as an image_url data URL",
            image.png.len(),
            image.width_px,
            image.height_px
        )?,
        None => writeln!(sink, "  image    : no")?,
    }
    writeln!(
        sink,
        "  body     : {} bytes of JSON (stream: {})",
        spec.body.len(),
        if plan.parts[0].wire_body.contains("\"stream\":true") {
            "yes"
        } else {
            "no"
        }
    )?;
    for (name, value) in &spec.headers {
        if name.eq_ignore_ascii_case("authorization") {
            writeln!(sink, "  header   : {name}: Bearer <redacted>")?;
        } else {
            writeln!(sink, "  header   : {name}: {value}")?;
        }
    }
    if plan.is_local {
        writeln!(sink, "  host     : loopback")?;
    } else {
        writeln!(
            sink,
            "  host     : remote — --yes-remote was passed; this prompt leaves this Mac"
        )?;
    }
    writeln!(sink)?;
    sink.flush()
}

#[derive(Debug)]
struct ProbeOutcome {
    usage: TokenUsage,
    diagnostics: Option<StreamDiagnostics>,
    duration: Duration,
    first_token: Option<Duration>,
    answer_characters: usize,
}

fn execute(
    plan: &ChatPlan,
    key: &str,
    transport: &dyn Transport,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<ProbeOutcome, AiError> {
    let started = Instant::now();
    let cancel = CancellationToken::new();
    let mut usage = TokenUsage::default();
    let mut diagnostics = None;
    let mut first_token = None;
    let mut answer_characters = 0usize;
    let mut reasoning_open = false;

    let result = run_plan_with_transport(plan, key, transport, &cancel, &mut |event| match event {
        RunEvent::Delta(delta) => {
            if first_token.is_none() {
                first_token = Some(started.elapsed());
            }
            answer_characters += delta.chars().count();
            // Streaming is the point: write and flush each delta as it arrives.
            let _ = out.write_all(delta.as_bytes());
            let _ = out.flush();
        }
        RunEvent::ReasoningDelta(delta) => {
            if first_token.is_none() {
                first_token = Some(started.elapsed());
            }
            if !reasoning_open {
                let _ = writeln!(err, "[reasoning]");
                reasoning_open = true;
            }
            let _ = err.write_all(delta.as_bytes());
            let _ = err.flush();
        }
        RunEvent::Usage(values) => usage = usage.merge(values),
        RunEvent::Diagnostics(values) => diagnostics = Some(values),
        _ => {}
    });
    let duration = started.elapsed();
    if reasoning_open {
        let _ = writeln!(err);
    }
    result.map(|()| ProbeOutcome {
        usage,
        diagnostics,
        duration,
        first_token,
        answer_characters,
    })
}

fn summary_line(plan: &ChatPlan, outcome: &ProbeOutcome) -> String {
    let usage = if outcome.usage.is_empty() {
        outcome
            .diagnostics
            .as_ref()
            .map(|diagnostics| diagnostics.usage)
            .unwrap_or_default()
    } else {
        outcome.usage
    };
    let tokens = |value: Option<u64>| {
        value
            .map(|value| value.to_string())
            .unwrap_or_else(|| "not-reported".to_string())
    };
    let first_token = outcome
        .first_token
        .map(|duration| format!("{:.3}s", duration.as_secs_f64()))
        .unwrap_or_else(|| "not-seen".to_string());
    format!(
        "summary: prompt_tokens={} completion_tokens={} total_tokens={} duration={:.3}s ttft={first_token} endpoint={} model={}",
        tokens(usage.prompt_tokens),
        tokens(usage.completion_tokens),
        tokens(usage.total_tokens),
        outcome.duration.as_secs_f64(),
        plan.endpoint,
        plan.model
    )
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use lyra_reader_ai::openai::ResponseStream;

    use super::*;

    fn probe_args(values: &[&str]) -> ProbeArgs {
        let values: Vec<String> = values.iter().map(|value| value.to_string()).collect();
        parse_args(&values).expect("probe arguments")
    }

    fn local_args() -> ProbeArgs {
        probe_args(&[
            "--base-url",
            "http://127.0.0.1:9/v1",
            "--model",
            "test-model",
            "--api-key",
            "sk-test-not-a-real-key",
            "--prompt",
            "Say pong.",
            "--max-tokens",
            "64",
        ])
    }

    fn prepare_error(args: &ProbeArgs) -> String {
        match prepare(args) {
            Ok(_) => panic!("prepare unexpectedly succeeded"),
            Err(message) => message,
        }
    }

    fn header<'a>(spec: &'a RequestSpec, name: &str) -> Option<&'a str> {
        spec.headers
            .iter()
            .find(|(candidate, _)| candidate.eq_ignore_ascii_case(name))
            .map(|(_, value)| value.as_str())
    }

    #[test]
    fn probe_builds_the_expected_request_body() {
        let args = local_args();
        let prepared = prepare(&args).expect("prepare");
        assert_eq!(prepared.spec.url, "http://127.0.0.1:9/v1/chat/completions");
        assert_eq!(prepared.spec.method, "POST");
        assert_eq!(
            header(&prepared.spec, "authorization"),
            Some("Bearer sk-test-not-a-real-key")
        );
        assert_eq!(
            header(&prepared.spec, "content-type"),
            Some("application/json")
        );
        assert_eq!(header(&prepared.spec, "accept"), Some("text/event-stream"));

        let body: serde_json::Value = serde_json::from_slice(&prepared.spec.body).unwrap();
        assert_eq!(body["model"], "test-model");
        assert_eq!(body["stream"], true);
        assert_eq!(body["stream_options"]["include_usage"], true);
        assert_eq!(body["max_tokens"], 64);
        let temperature = body["temperature"].as_f64().expect("temperature");
        assert!(
            (temperature - 0.2).abs() < 1e-6,
            "temperature: {temperature}"
        );
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["messages"][1]["content"], "Say pong.");
        assert!(body.get("image_url").is_none());
        assert!(body["messages"][1].get("image_url").is_none());
        assert_eq!(
            prepared.spec.body,
            prepared.plan.parts[0].wire_body.as_bytes(),
            "the bytes on the wire must be exactly the previewed body"
        );
        assert!(prepared.plan.is_local);
    }

    #[test]
    fn no_stream_body_asks_for_one_json_response() {
        let args = probe_args(&[
            "--base-url",
            "http://127.0.0.1:9/v1",
            "--model",
            "test-model",
            "--api-key",
            "sk-test-not-a-real-key",
            "--prompt",
            "Say pong.",
            "--no-stream",
        ]);
        let prepared = prepare(&args).expect("prepare");
        let body: serde_json::Value = serde_json::from_slice(&prepared.spec.body).unwrap();
        assert_eq!(body["stream"], false);
        assert!(
            body.get("stream_options").is_none(),
            "a non-streaming request must not carry stream_options"
        );
    }

    #[test]
    fn a_png_is_embedded_as_an_image_url_data_url() {
        let png = tiny_png();
        let args = local_args();
        let plan = plan_for(
            &args,
            Some(ChatImage {
                width_px: 1,
                height_px: 1,
                png: png.clone(),
            }),
        )
        .expect("plan");
        let spec = build_request_spec(&plan, &plan.parts[0], "sk-test-not-a-real-key").unwrap();
        let body: serde_json::Value = serde_json::from_slice(&spec.body).unwrap();
        let content = &body["messages"][1]["content"];
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[0]["text"], "Say pong.");
        assert_eq!(content[1]["type"], "image_url");
        let url = content[1]["image_url"]["url"].as_str().unwrap();
        assert!(url.starts_with("data:image/png;base64,"), "url: {url}");
        assert_eq!(plan.parts[0].image.as_ref().unwrap().png, png);
    }

    #[test]
    fn load_png_keeps_the_bytes_and_reads_the_dimensions() {
        let png = tiny_png();
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let path = std::env::temp_dir().join(format!(
            "lyra-reader-probe-{}-{unique}.png",
            std::process::id()
        ));
        std::fs::write(&path, &png).unwrap();
        let loaded = load_png(&path).expect("load PNG");
        std::fs::remove_file(&path).ok();
        assert_eq!(loaded.width_px, 1);
        assert_eq!(loaded.height_px, 1);
        assert_eq!(loaded.png, png);
    }

    #[test]
    fn a_non_png_is_refused_before_anything_is_sent() {
        let path = std::env::temp_dir().join(format!(
            "lyra-reader-probe-{}-not-a-png.png",
            std::process::id()
        ));
        std::fs::write(&path, b"not a png").unwrap();
        let error = load_png(&path).expect_err("must reject");
        std::fs::remove_file(&path).ok();
        assert!(error.contains("not a PNG"), "error: {error}");
    }

    #[test]
    fn non_loopback_hosts_are_refused_without_yes_remote() {
        let remote = inspect_base_url("http://192.0.2.10:8080/v1").expect("remote endpoint");
        assert!(!remote.is_local);
        let error = refuse_non_loopback(&remote, false).expect_err("must refuse");
        assert!(error.contains("--yes-remote"), "error: {error}");
        assert!(refuse_non_loopback(&remote, true).is_ok());

        for local in [
            "http://127.0.0.1:8080/v1",
            "http://localhost:8080/v1",
            "http://[::1]:8080/v1",
        ] {
            let endpoint = inspect_base_url(local).expect("loopback endpoint");
            assert!(endpoint.is_local, "{local}");
            assert!(refuse_non_loopback(&endpoint, false).is_ok(), "{local}");
        }

        let args = probe_args(&[
            "--base-url",
            "http://192.0.2.10:8080/v1",
            "--model",
            "test-model",
            "--prompt",
            "hello",
        ]);
        assert!(!args.yes_remote);
        let error = prepare_error(&args);
        assert!(error.contains("--yes-remote"), "error: {error}");

        let confirmed = probe_args(&[
            "--base-url",
            "http://192.0.2.10:8080/v1",
            "--model",
            "test-model",
            "--api-key",
            "sk-test-not-a-real-key",
            "--prompt",
            "hello",
            "--yes-remote",
        ]);
        assert!(confirmed.yes_remote);
        assert!(
            prepare(&confirmed).is_ok(),
            "--yes-remote must allow the same host"
        );
    }

    #[test]
    fn a_missing_key_uses_the_client_message() {
        let args = probe_args(&[
            "--base-url",
            "http://127.0.0.1:9/v1",
            "--model",
            "test-model",
            "--prompt",
            "hello",
        ]);
        // Ignore a key that may be exported in the developer's shell; the test is about the
        // client's own refusal path, not about the environment.
        let args = ProbeArgs {
            api_key: None,
            ..args
        };
        let error = prepare_error(&args);
        assert!(error.contains("No API key is configured"), "error: {error}");
        assert!(error.contains("nothing was sent"), "error: {error}");
    }

    #[test]
    fn a_scripted_transport_streams_the_text_and_reports_usage() {
        let args = local_args();
        let prepared = prepare(&args).expect("prepare");
        let transport = ScriptedTransport::stream(vec![
            b"data: {\"choices\":[{\"delta\":{\"content\":\"po\"}}]}\n\n".to_vec(),
            b"data: {\"choices\":[{\"delta\":{\"content\":\"ng\"}}]}\n\n".to_vec(),
            b"data: {\"choices\":[],\"usage\":{\"prompt_tokens\":7,\"completion_tokens\":2,\"total_tokens\":9}}\n\n".to_vec(),
            b"data: [DONE]\n\n".to_vec(),
        ]);
        let mut out = Vec::new();
        let mut err = Vec::new();
        let outcome = execute(
            &prepared.plan,
            &prepared.key,
            &transport,
            &mut out,
            &mut err,
        )
        .expect("stream");
        assert_eq!(String::from_utf8(out).unwrap(), "pong");
        assert_eq!(outcome.usage.prompt_tokens, Some(7));
        assert_eq!(outcome.usage.completion_tokens, Some(2));
        assert_eq!(outcome.usage.total_tokens, Some(9));
        assert!(outcome.first_token.is_some());
        assert!(outcome.answer_characters == 4);

        let summary = summary_line(&prepared.plan, &outcome);
        assert!(summary.contains("prompt_tokens=7"), "summary: {summary}");
        assert!(
            summary.contains("completion_tokens=2"),
            "summary: {summary}"
        );
        assert!(summary.contains("ttft="), "summary: {summary}");
        assert!(
            summary.contains("endpoint=http://127.0.0.1:9/v1/chat/completions"),
            "summary: {summary}"
        );
        assert!(summary.contains("model=test-model"), "summary: {summary}");

        let recorded = transport.recorded.lock().unwrap().clone().unwrap();
        assert_eq!(recorded.body, prepared.spec.body);
        assert_eq!(recorded.url, prepared.spec.url);
    }

    #[test]
    fn an_http_error_uses_the_client_mapping() {
        let args = local_args();
        let prepared = prepare(&args).expect("prepare");
        let transport = ScriptedTransport::error(
            500,
            b"{\"error\":{\"message\":\"probe exploded\"}}".to_vec(),
        );
        let mut out = Vec::new();
        let mut err = Vec::new();
        let error = execute(
            &prepared.plan,
            &prepared.key,
            &transport,
            &mut out,
            &mut err,
        )
        .expect_err("HTTP 500 must fail");
        let message = error.to_string();
        assert!(message.contains("provider failed"), "message: {message}");
        assert!(message.contains("HTTP 500"), "message: {message}");
        assert!(message.contains("probe exploded"), "message: {message}");
    }

    fn tiny_png() -> Vec<u8> {
        let image = image::RgbaImage::from_pixel(1, 1, image::Rgba([220, 40, 40, 255]));
        let mut cursor = Cursor::new(Vec::new());
        image::DynamicImage::ImageRgba8(image)
            .write_to(&mut cursor, image::ImageFormat::Png)
            .expect("encode PNG");
        cursor.into_inner()
    }

    #[derive(Clone)]
    struct Recorded {
        url: String,
        body: Vec<u8>,
    }

    struct ScriptedTransport {
        status: u16,
        chunks: Vec<Vec<u8>>,
        recorded: Arc<Mutex<Option<Recorded>>>,
    }

    impl ScriptedTransport {
        fn stream(chunks: Vec<Vec<u8>>) -> Self {
            Self {
                status: 200,
                chunks,
                recorded: Arc::new(Mutex::new(None)),
            }
        }

        fn error(status: u16, body: Vec<u8>) -> Self {
            Self {
                status,
                chunks: vec![body],
                recorded: Arc::new(Mutex::new(None)),
            }
        }
    }

    impl Transport for ScriptedTransport {
        fn execute(
            &self,
            spec: &RequestSpec,
            _cancel: &CancellationToken,
        ) -> Result<Box<dyn ResponseStream>, AiError> {
            *self.recorded.lock().unwrap() = Some(Recorded {
                url: spec.url.clone(),
                body: spec.body.clone(),
            });
            Ok(Box::new(ScriptedStream {
                status: self.status,
                chunks: self.chunks.clone().into_iter(),
                headers: vec![(
                    "content-type".to_string(),
                    if (200..300).contains(&self.status) {
                        "text/event-stream".to_string()
                    } else {
                        "application/json".to_string()
                    },
                )],
            }))
        }
    }

    struct ScriptedStream {
        status: u16,
        chunks: std::vec::IntoIter<Vec<u8>>,
        headers: Vec<(String, String)>,
    }

    impl ResponseStream for ScriptedStream {
        fn status(&self) -> u16 {
            self.status
        }

        fn reason(&self) -> &str {
            if (200..300).contains(&self.status) {
                "OK"
            } else {
                "Internal Server Error"
            }
        }

        fn headers(&self) -> &[(String, String)] {
            &self.headers
        }

        fn next_chunk(&mut self) -> Result<Option<Vec<u8>>, AiError> {
            Ok(self.chunks.next())
        }
    }
}
