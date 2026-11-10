use std::env;
use std::path::Path;

const DEFAULT_PATH: &str = "nnue/files/quantised.bin";

fn main() {
    println!("cargo:rerun-if-env-changed=EVALFILE");
    println!("cargo:rerun-if-env-changed=PEA_UCI_DATE");
    println!("cargo:rerun-if-changed={}", DEFAULT_PATH);

    let eval_file = env::var("EVALFILE").unwrap_or_else(|_| DEFAULT_PATH.to_owned());

    if eval_file != DEFAULT_PATH {
        if let Some(parent) = Path::new(DEFAULT_PATH).parent() {
            std::fs::create_dir_all(parent)
                .unwrap_or_else(|e| panic!("Failed to create NNUE directory '{}': {}", parent.display(), e));
        }
        std::fs::copy(&eval_file, DEFAULT_PATH).unwrap_or_else(|e| {
            panic!(
                "Failed to copy NNUE network '{}' to '{}': {}",
                eval_file, DEFAULT_PATH, e
            )
        });
    }

    if !Path::new(DEFAULT_PATH).is_file() {
        panic!(
            "Required Pea NNUE network is missing: '{}'. Place the original quantised.bin there \
             or set EVALFILE to its path before building. No substitute network is generated.",
            DEFAULT_PATH
        );
    }

    let uci_date = env::var("PEA_UCI_DATE").unwrap_or_else(|_| "unknown".to_owned());
    if uci_date != "unknown"
        && (uci_date.len() != 8 || !uci_date.bytes().all(|b| b.is_ascii_digit()))
    {
        panic!("PEA_UCI_DATE must use YYYYMMDD format, got '{}'", uci_date);
    }
    println!("cargo:rustc-env=PEA_UCI_DATE={}", uci_date);
}
