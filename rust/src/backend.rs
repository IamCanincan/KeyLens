//! 后端探测：与 `lib/backend.sh` 的 `detect_backend` 同语义。
//!
//! 规则（顺序敏感）：
//!   1. teesim 模块目录存在且没有 `disable` 文件 → teesim
//!   2. tricky 模块目录同上 → tricky
//!   3. omk 模块目录同上 → omk
//!   4. 都没有时：`config.json` 存在 → teesim，否则 → tricky
//!
//! 路径与 `lib/core.sh` 的常量一致；测试可用 `KEYLENS_ROOT` 改写根前缀
//! （生产环境不设，就是绝对路径）。

use std::path::{Path, PathBuf};

/// 路径根：测试时指向临时目录，生产为空串（绝对路径）。
#[derive(Clone, Debug)]
pub struct Root {
    prefix: PathBuf,
}

impl Root {
    pub fn from_env() -> Self {
        Root { prefix: PathBuf::from(std::env::var("KEYLENS_ROOT").unwrap_or_default()) }
    }

    /// 把 `/data/...` 这类绝对路径落到根前缀下。
    pub fn join(&self, abs: &str) -> PathBuf {
        if self.prefix.as_os_str().is_empty() {
            PathBuf::from(abs)
        } else {
            self.prefix.join(abs.trim_start_matches('/'))
        }
    }
}

/// 与 core.sh 的常量一一对应。
pub struct Paths {
    pub tstore_dir: PathBuf,
    pub teesim_dir: PathBuf,
    pub teesim_config: PathBuf,
    pub omk_dir: PathBuf,
    pub omk_injector: PathBuf,
    pub omk_state_dir: PathBuf,
    pub tricky_module: PathBuf,
    pub teesim_module: PathBuf,
    pub omk_module: PathBuf,
    pub log: PathBuf,
    pub module_prop: PathBuf,
    pub props_off: PathBuf,
    pub boot_hash: PathBuf,
}

impl Paths {
    pub fn new(root: &Root) -> Self {
        Paths {
            tstore_dir: root.join("/data/adb/tricky_store"),
            teesim_dir: root.join("/data/adb/teesim"),
            teesim_config: root.join("/data/adb/teesim/config.json"),
            omk_dir: root.join("/data/misc/keystore/omk"),
            omk_injector: root.join("/data/misc/keystore/omk/injector.toml"),
            omk_state_dir: root.join("/data/adb/omk"),
            tricky_module: root.join("/data/adb/modules/tricky_store"),
            teesim_module: root.join("/data/adb/modules/teesim"),
            omk_module: root.join("/data/adb/modules/oh_my_keymint"),
            log: root.join("/data/adb/keylens.log"),
            module_prop: {
                // 模块目录：KEYLENS_MODDIR 优先，其次「二进制在 bin/ 下」推导（非默认安装位置也对）
                let md = std::env::var("KEYLENS_MODDIR").ok().or_else(|| {
                    let exe = std::env::current_exe().ok()?;
                    let bin = exe.parent()?;
                    if bin.file_name().map(|n| n == "bin").unwrap_or(false) {
                        Some(bin.parent()?.to_string_lossy().into_owned())
                    } else {
                        None
                    }
                });
                match md {
                    Some(d) => std::path::PathBuf::from(d).join("module.prop"),
                    None => root.join("/data/adb/modules/keylens/module.prop"),
                }
            },
            props_off: root.join("/data/adb/keylens.props_off"),
            boot_hash: root.join("/data/adb/keylens.boot_hash"),
        }
    }
}

pub fn active(module_dir: &Path) -> bool {
    module_dir.is_dir() && !module_dir.join("disable").exists()
}

#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum BackendId {
    Teesim,
    Tricky,
    Omk,
}

impl BackendId {
    pub fn as_str(self) -> &'static str {
        match self {
            BackendId::Teesim => "teesim",
            BackendId::Tricky => "tricky",
            BackendId::Omk => "omk",
        }
    }
}

#[derive(Debug)]
pub struct Backend {
    pub id: BackendId,
    /// 运行期状态与备份所在目录（KL_DIR）
    pub dir: PathBuf,
    /// 目标文件（TARGET_FILE）
    pub target: PathBuf,
}

pub fn detect(p: &Paths) -> Backend {
    if active(&p.teesim_module) {
        teesim(p)
    } else if active(&p.tricky_module) {
        tricky(p)
    } else if active(&p.omk_module) {
        omk(p)
    } else if p.teesim_config.is_file() {
        teesim(p)
    } else {
        tricky(p)
    }
}

fn teesim(p: &Paths) -> Backend {
    Backend { id: BackendId::Teesim, dir: p.teesim_dir.clone(), target: p.teesim_config.clone() }
}
fn tricky(p: &Paths) -> Backend {
    Backend { id: BackendId::Tricky, dir: p.tstore_dir.clone(), target: p.tstore_dir.join("target.txt") }
}
fn omk(p: &Paths) -> Backend {
    Backend { id: BackendId::Omk, dir: p.omk_state_dir.clone(), target: p.omk_injector.clone() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("keylens-test-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn detects_teesim_first() {
        let root = tmp("teesim");
        fs::create_dir_all(root.join("data/adb/modules/teesim")).unwrap();
        fs::create_dir_all(root.join("data/adb/modules/tricky_store")).unwrap();
        let p = Paths::new(&Root { prefix: root.clone() });
        assert_eq!(detect(&p).id, BackendId::Teesim);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn disabled_module_is_skipped() {
        let root = tmp("disabled");
        let m = root.join("data/adb/modules/tricky_store");
        fs::create_dir_all(&m).unwrap();
        fs::write(m.join("disable"), b"").unwrap();
        fs::create_dir_all(root.join("data/adb/modules/oh_my_keymint")).unwrap();
        let p = Paths::new(&Root { prefix: root.clone() });
        assert_eq!(detect(&p).id, BackendId::Omk);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn fallback_teesim_config_then_tricky() {
        let root = tmp("fallback");
        let p = Paths::new(&Root { prefix: root.clone() });
        assert_eq!(detect(&p).id, BackendId::Tricky);
        fs::create_dir_all(root.join("data/adb/teesim")).unwrap();
        fs::write(root.join("data/adb/teesim/config.json"), b"{}").unwrap();
        assert_eq!(detect(&p).id, BackendId::Teesim);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn dir_and_target_per_backend() {
        let root = tmp("dirs");
        let p = Paths::new(&Root { prefix: root.clone() });
        let b = teesim(&p);
        assert_eq!(b.dir, root.join("data/adb/teesim"));
        assert_eq!(b.target, root.join("data/adb/teesim/config.json"));
        let b = tricky(&p);
        assert_eq!(b.dir, root.join("data/adb/tricky_store"));
        assert_eq!(b.target, root.join("data/adb/tricky_store/target.txt"));
        let b = omk(&p);
        assert_eq!(b.dir, root.join("data/adb/omk"));
        assert_eq!(b.target, root.join("data/misc/keystore/omk/injector.toml"));
        let _ = fs::remove_dir_all(&root);
    }
}
