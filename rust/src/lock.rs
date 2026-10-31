//! 并发锁：与 `lib/lock.sh` 同语义（目录原子创建 + 持有者证据）。
//!
//! 为什么不能"超时就抢"：锁目录平时是空的，`rmdir` 对空目录会成功 —— 那会把
//! 守护进程手里的锁拆掉，两边同时整文件读-改-写。所以接管必须先证明持有者已死：
//! 进程不存在，或 `/proc/<pid>/cmdline` 里没有本模块的标记。

use std::path::{Path, PathBuf};
use std::time::Duration;

fn holder_alive(pid: &str, marks: &[String]) -> bool {
    let proc_dir = PathBuf::from(format!("/proc/{}", pid));
    if !proc_dir.exists() {
        return false;
    }
    let cmdline = match std::fs::read(proc_dir.join("cmdline")) {
        Ok(data) => data,
        Err(_) => return true, // 读不到按"活着"处理：宁可这次不写
    };
    let text = String::from_utf8_lossy(&cmdline).replace('\0', " ");
    marks.iter().filter(|m| !m.is_empty()).any(|m| text.contains(m.as_str()))
}

/// 取锁：成功后 `dir/pid` 里是当前进程号。返回 false 表示这轮不要写。
pub fn acquire(dir: &Path, timeout_secs: u64, marks: &[String]) -> bool {
    let me = std::process::id().to_string();
    for _ in 0..timeout_secs {
        if std::fs::create_dir(dir).is_ok() {
            let _ = std::fs::write(dir.join("pid"), me.as_bytes());
            return true;
        }
        std::thread::sleep(Duration::from_secs(1));
    }
    let pid = std::fs::read_to_string(dir.join("pid")).unwrap_or_default();
    let pid = pid.trim();
    let valid = !pid.is_empty() && pid.bytes().all(|b| b.is_ascii_digit());
    if valid && holder_alive(pid, marks) {
        return false;
    }
    let _ = std::fs::remove_file(dir.join("pid"));
    let _ = std::fs::remove_dir(dir);
    if std::fs::create_dir(dir).is_ok() {
        let _ = std::fs::write(dir.join("pid"), me.as_bytes());
        return true;
    }
    false
}

/// 释放：只有 pid 记录是本进程才拆（否则会把接管者的锁拆掉）。
pub fn release(dir: &Path) {
    let me = std::process::id().to_string();
    if std::fs::read_to_string(dir.join("pid")).map(|p| p.trim() == me).unwrap_or(false) {
        let _ = std::fs::remove_file(dir.join("pid"));
        let _ = std::fs::remove_dir(dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("keylens-lock-{}-{}", tag, std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn acquire_then_release() {
        let d = tmp("basic").join("lockdir");
        let marks = vec!["keylens".to_string()];
        assert!(acquire(&d, 1, &marks));
        assert!(d.join("pid").is_file());
        release(&d);
        assert!(!d.exists());
    }

    #[test]
    fn second_acquire_fails_while_held() {
        let d = tmp("held").join("lockdir");
        let marks = vec!["keylens".to_string()];
        assert!(acquire(&d, 1, &marks));
        // 自己持有：超时后持有者活着 → 失败
        assert!(!acquire(&d, 1, &marks));
        release(&d);
    }

    #[test]
    fn stale_lock_is_taken_over() {
        let d = tmp("stale").join("lockdir");
        std::fs::create_dir_all(&d).unwrap();
        // 一个几乎肯定不存在的 pid
        std::fs::write(d.join("pid"), b"999999999").unwrap();
        let marks = vec!["keylens".to_string()];
        assert!(acquire(&d, 1, &marks));
        release(&d);
    }

    #[test]
    fn release_foreign_lock_is_noop() {
        let d = tmp("foreign").join("lockdir");
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("pid"), b"424242").unwrap();
        release(&d);
        assert!(d.exists(), "别人的锁不许被我拆掉");
    }
}
