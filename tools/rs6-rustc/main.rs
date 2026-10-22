// SPDX-License-Identifier: MIT
// rs6-rustc: the `rustc` of the rs6-builder container (mkxtools-rs6.sh, xtools-activate.sh). It is
// the rustup toolchain's x86_64 compiler (rustc_driver of rust 1.99.1, the version bens has), so it
// runs natively, but to the AArch64 container it looks like a native AArch64 rustc, the way the
// x86_64 gcc in /usr/bin looks like bens' gcc:
//   - no --target: the target is aarch64-unknown-linux-gnu (std from the toolchain's rust-std),
//     linked with `cc`, which is the native gcc of the container;
//   - `rustc -vV` and `--print host-tuple` say aarch64-unknown-linux-gnu.
// The only thing a native AArch64 rustc does that an x86_64 process cannot is load an AArch64
// proc macro. So every rlib and proc-macro crate built without --target is also built for
// x86_64 next to it, in a .rs6-host directory beside each output ("twin"), and when a compile
// loads a proc macro it gets the x86_64 twin. The outputs at the normal paths are all AArch64,
// exactly what a native build makes (an installed proc macro, e.g. the kernel's libmacros.so in
// linux-headers, is the AArch64 one). Build systems see nothing of this: no flags, no wrappers.
// Twin proc macros are linked with the x86_64 gcc in /opt/rs6-xtools/x86_64 (a link-only Arch
// x86_64 sysroot). A twin that fails to build (code that only builds for AArch64) is left out;
// its log is <output dir>/.rs6-host/<crate>.log.
// Explicit --target compiles (the kernel's own crates) keep their target; they too get the x86_64
// twin of every proc macro they load.
#![feature(rustc_private)]

extern crate rustc_driver;
extern crate rustc_session;

use std::env;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

const TARGET: &str = "aarch64-unknown-linux-gnu";
const BUILD: &str = "x86_64-unknown-linux-gnu";
const TWIN: &str = ".rs6-host";
const XROOT: &str = "/opt/rs6-xtools/x86_64";

struct Callbacks;
impl rustc_driver::Callbacks for Callbacks {}

// options that take a value (as a separate token, or attached: -Lx, -Cx=y, --opt=x)
const VALUE_OPTS: &[&str] = &[
    "-L", "-l", "-o", "-C", "-Z", "-W", "-A", "-D", "-F", "--cap-lints", "--crate-type", "--crate-name",
    "--edition", "--emit", "--print", "--out-dir", "--explain", "--target", "--extern", "--sysroot",
    "--error-format", "--json", "--color", "--diagnostic-width", "--remap-path-prefix", "--cfg",
    "--check-cfg", "--codegen", "--force-warn", "--warn", "--allow", "--deny", "--forbid", "--env-set",
];

#[derive(Clone)]
enum Arg {
    Opt(String, String), // name, value
    Plain(String),       // flags and inputs
}

fn parse(args: &[String]) -> Vec<Arg> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        i += 1;
        if a.starts_with("--") {
            if let Some((n, v)) = a.split_once('=') {
                if VALUE_OPTS.contains(&n) {
                    out.push(Arg::Opt(n.to_string(), v.to_string()));
                    continue;
                }
            } else if VALUE_OPTS.contains(&a.as_str()) && i < args.len() {
                out.push(Arg::Opt(a.clone(), args[i].clone()));
                i += 1;
                continue;
            }
            out.push(Arg::Plain(a.clone()));
        } else if a.len() >= 2 && a.starts_with('-') && VALUE_OPTS.contains(&&a[..2]) {
            let n = a[..2].to_string();
            if a.len() > 2 {
                out.push(Arg::Opt(n, a[2..].to_string()));
            } else if i < args.len() {
                out.push(Arg::Opt(n, args[i].clone()));
                i += 1;
            } else {
                out.push(Arg::Plain(a.clone()));
            }
        } else {
            out.push(Arg::Plain(a.clone()));
        }
    }
    out
}

fn unparse(args: &[Arg]) -> Vec<String> {
    let mut out = Vec::new();
    for a in args {
        match a {
            Arg::Opt(n, v) => {
                out.push(n.clone());
                out.push(v.clone());
            }
            Arg::Plain(p) => out.push(p.clone()),
        }
    }
    out
}

fn twin_of(p: &str) -> PathBuf {
    let p = Path::new(p);
    let dir = p.parent().filter(|d| !d.as_os_str().is_empty()).unwrap_or(Path::new("."));
    match p.file_name() {
        Some(f) => dir.join(TWIN).join(f),
        None => dir.join(TWIN),
    }
}

fn twin_dir(d: &str) -> PathBuf {
    Path::new(d).join(TWIN)
}

// -C key=value or --codegen key=value: the key
fn cg_key(a: &Arg) -> Option<&str> {
    match a {
        Arg::Opt(n, v) if n == "-C" || n == "--codegen" => Some(v.split('=').next().unwrap_or("")),
        _ => None,
    }
}

// --extern [modifiers:]name=path
fn extern_twin(v: &str, only_dylib: bool) -> Option<String> {
    let (lhs, path) = v.split_once('=')?;
    if only_dylib && !path.ends_with(".so") {
        return None;
    }
    let t = twin_of(path);
    t.exists().then(|| format!("{lhs}={}", t.display()))
}

// --extern [modifiers:]name (no path) that names a proc macro in one of the -L dirs -> its twin, by path
fn extern_by_name(v: &str, search: &[String]) -> Option<String> {
    if v.contains('=') {
        return None;
    }
    let name = v.rsplit(':').next().unwrap_or(v);
    search.iter().find_map(|d| {
        let t = twin_dir(d).join(format!("lib{name}.so"));
        t.exists().then(|| format!("{v}={}", t.display()))
    })
}

// -L [kind=]dir -> its twin, if there is one
fn search_twin(v: &str) -> Option<String> {
    let (kind, dir) = match v.split_once('=') {
        Some((k, d)) if ["dependency", "crate", "native", "framework", "all"].contains(&k) => (Some(k), d),
        _ => (None, v),
    };
    let t = twin_dir(dir);
    t.is_dir().then(|| match kind {
        Some(k) => format!("{k}={}", t.display()),
        None => t.display().to_string(),
    })
}

fn run(args: &[String]) -> ExitCode {
    rustc_driver::catch_with_exit_code(|| rustc_driver::run_compiler(args, &mut Callbacks))
}

fn reraw(args: &[String]) -> Command {
    let mut c = Command::new(env::current_exe().expect("current_exe"));
    c.args(&args[1..]).env("RS6_RUSTC_RAW", "1");
    c
}

fn main() -> ExitCode {
    let early = rustc_session::EarlyDiagCtxt::new(rustc_session::config::ErrorOutputType::default());
    rustc_driver::init_rustc_env_logger(&early);
    rustc_driver::install_ice_hook(rustc_driver::DEFAULT_BUG_REPORT_URL, |_| ());
    rustc_driver::install_ctrlc_handler();
    let raw = rustc_driver::args::raw_args(&early);
    if env::var_os("RS6_RUSTC_RAW").is_some() {
        return run(&raw);
    }
    let expanded = rustc_driver::args::arg_expand_all(&early, &raw);
    let parsed = parse(&expanded[1..]);

    let has_target = parsed.iter().any(|a| matches!(a, Arg::Opt(n, _) if n == "--target"));
    let mut primary: Vec<Arg> = Vec::new();
    if !has_target {
        primary.push(Arg::Opt("--target".into(), TARGET.into()));
    }
    // a proc macro is loaded into this (x86_64) process: every compile, --target or not, gets the
    // x86_64 twin of each proc macro it names, by path or by name through the -L dirs
    let search: Vec<String> = parsed
        .iter()
        .filter_map(|a| match a {
            Arg::Opt(n, v) if n == "-L" => Some(v.split_once('=').map_or(v.as_str(), |(k, d)| {
                if ["dependency", "crate", "native", "framework", "all"].contains(&k) { d } else { v.as_str() }
            }).to_string()),
            _ => None,
        })
        .collect();
    for a in &parsed {
        match a {
            Arg::Opt(n, v) if n == "--extern" => {
                let t = extern_twin(v, true).or_else(|| extern_by_name(v, &search));
                primary.push(Arg::Opt(n.clone(), t.unwrap_or_else(|| v.clone())));
            }
            Arg::Opt(n, v) if n == "-L" => {
                if let Some(t) = search_twin(v) {
                    primary.push(Arg::Opt(n.clone(), t));
                }
                primary.push(a.clone());
            }
            _ => primary.push(a.clone()),
        }
    }
    let mut primary_args = vec![expanded[0].clone()];
    primary_args.extend(unparse(&primary));

    // what this rustc says it runs on: AArch64
    let plain = |p: &str| parsed.iter().any(|a| matches!(a, Arg::Plain(x) if x == p));
    let version = plain("-V") || plain("--version") || plain("-vV") || plain("-Vv");
    let verbose = plain("-v") || plain("--verbose") || plain("-vV") || plain("-Vv");
    let print_host = parsed.iter().any(|a| {
        matches!(a, Arg::Opt(n, v) if n == "--print" && v.split(',').any(|k| k == "host-tuple"))
    });
    if (version && verbose) || print_host {
        let out = match reraw(&primary_args).stdin(Stdio::inherit()).stderr(Stdio::inherit()).output() {
            Ok(o) => o,
            Err(e) => {
                eprintln!("rs6-rustc: {e}");
                return ExitCode::FAILURE;
            }
        };
        let text = String::from_utf8_lossy(&out.stdout);
        let mut so = std::io::stdout().lock();
        for line in text.split_inclusive('\n') {
            let (body, nl) = line.strip_suffix('\n').map_or((line, ""), |b| (b, "\n"));
            if body == format!("host: {BUILD}") {
                let _ = write!(so, "host: {TARGET}{nl}");
            } else if print_host && body == BUILD {
                let _ = write!(so, "{TARGET}{nl}");
            } else {
                let _ = write!(so, "{body}{nl}");
            }
        }
        let _ = so.flush();
        return if out.status.success() { ExitCode::SUCCESS } else { ExitCode::from(out.status.code().unwrap_or(1) as u8) };
    }

    if has_target {
        return run(&primary_args);
    }

    // the x86_64 twin of an rlib or proc-macro crate
    let crate_types: Vec<String> = parsed
        .iter()
        .filter_map(|a| match a {
            Arg::Opt(n, v) if n == "--crate-type" => Some(v.split(',').map(str::to_string).collect::<Vec<_>>()),
            _ => None,
        })
        .flatten()
        .collect();
    let stdin_input = plain("-");
    let wants_twin = crate_types.iter().any(|t| t == "rlib" || t == "lib" || t == "proc-macro") && !stdin_input;
    let mut twin_child = None;
    if wants_twin {
        if let Some((args, dirs, name)) = twin_args(&parsed, &crate_types, &search) {
            for d in &dirs {
                let _ = fs::create_dir_all(d);
            }
            let outdir = dirs[0].clone();
            let argfile = outdir.join(format!("{name}.args"));
            let log = outdir.join(format!("{name}.log"));
            let mut body = String::new();
            for a in &args {
                body.push_str(a);
                body.push('\n');
            }
            if fs::write(&argfile, body).is_ok() {
                if let Ok(logf) = fs::File::create(&log) {
                    let errf = logf.try_clone().ok();
                    let mut c = Command::new(env::current_exe().expect("current_exe"));
                    c.arg(format!("@{}", argfile.display()))
                        .env("RS6_RUSTC_RAW", "1")
                        .stdin(Stdio::null())
                        .stdout(logf);
                    if let Some(e) = errf {
                        c.stderr(e);
                    }
                    twin_child = c.spawn().ok();
                }
            }
        }
    }

    let code = run(&primary_args);
    if let Some(mut c) = twin_child {
        let _ = c.wait();
    }
    code
}

// twin compile line, its output dir and a name for the log; None if it would emit nothing
fn twin_args(parsed: &[Arg], crate_types: &[String], search: &[String]) -> Option<(Vec<String>, Vec<PathBuf>, String)> {
    let name = parsed
        .iter()
        .find_map(|a| match a {
            Arg::Opt(n, v) if n == "--crate-name" => Some(v.clone()),
            _ => None,
        })
        .unwrap_or_else(|| "crate".into());
    let mut out: Vec<Arg> = vec![Arg::Opt("--target".into(), BUILD.into())];
    let mut dirs: Vec<PathBuf> = Vec::new();
    let mut have_out = false;
    let mut have_emit = false;
    let mut emits_something = false;
    for a in parsed {
        match a {
            Arg::Opt(n, v) if n == "--extern" => {
                out.push(Arg::Opt(n.clone(), extern_twin(v, false).or_else(|| extern_by_name(v, search)).unwrap_or_else(|| v.clone())));
            }
            Arg::Opt(n, v) if n == "-L" => {
                if let Some(t) = search_twin(v) {
                    out.push(Arg::Opt(n.clone(), t));
                }
                out.push(a.clone());
            }
            Arg::Opt(n, v) if n == "-o" => {
                let t = twin_of(v);
                dirs.push(t.parent().unwrap().to_path_buf());
                have_out = true;
                out.push(Arg::Opt(n.clone(), t.display().to_string()));
            }
            Arg::Opt(n, v) if n == "--out-dir" => {
                let t = twin_dir(v);
                dirs.push(t.clone());
                have_out = true;
                out.push(Arg::Opt(n.clone(), t.display().to_string()));
            }
            Arg::Opt(n, v) if n == "--emit" => {
                have_emit = true;
                let mut kept = Vec::new();
                for item in v.split(',') {
                    let (kind, path) = match item.split_once('=') {
                        Some((k, p)) => (k, Some(p)),
                        None => (item, None),
                    };
                    if kind != "link" && kind != "metadata" {
                        continue;
                    }
                    match path {
                        Some(p) => {
                            let t = twin_of(p);
                            dirs.push(t.parent().unwrap().to_path_buf());
                            have_out = true;
                            kept.push(format!("{kind}={}", t.display()));
                        }
                        None => kept.push(kind.to_string()),
                    }
                }
                if !kept.is_empty() {
                    emits_something = true;
                    out.push(Arg::Opt(n.clone(), kept.join(",")));
                }
            }
            Arg::Opt(n, _) if n == "--target" => {}
            _ if matches!(cg_key(a), Some("linker" | "linker-flavor" | "target-cpu" | "target-feature" | "incremental")) => {}
            _ => out.push(a.clone()),
        }
    }
    if have_emit && !emits_something {
        return None;
    }
    // intermediate objects go to the output dir: without -o or --out-dir that is the current one,
    // shared with the primary compile running at the same time, so the twin gets its own
    let has_o = parsed.iter().any(|a| matches!(a, Arg::Opt(n, _) if n == "-o"));
    let has_out_dir = parsed.iter().any(|a| matches!(a, Arg::Opt(n, _) if n == "--out-dir"));
    if !has_o && !has_out_dir {
        let d = if have_out { dirs[0].clone() } else { PathBuf::from(TWIN) };
        out.push(Arg::Opt("--out-dir".into(), d.display().to_string()));
        dirs.push(d);
    }
    if crate_types.iter().any(|t| t == "proc-macro") {
        out.push(Arg::Opt("-C".into(), format!("linker={XROOT}/usr/bin/gcc")));
        out.push(Arg::Opt("-C".into(), format!("link-arg=--sysroot={XROOT}")));
        out.push(Arg::Opt("-C".into(), format!("link-arg=-B{XROOT}/usr/bin/")));
    }
    Some((unparse(&out), dirs, name))
}
