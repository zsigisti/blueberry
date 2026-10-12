//! Prompts for --cli mode. Each one checks its BLUEBERRY_* env var first, then
//! takes the default if BLUEBERRY_YES is set, and only then actually asks
//! (dialoguer, which is happy on a serial console).

use dialoguer::{theme::ColorfulTheme, Confirm, Input, Password, Select};
use std::env;

pub fn yes_mode() -> bool {
    env::var("BLUEBERRY_YES").map(|v| !v.is_empty()).unwrap_or(false)
}

fn env_val(key: &str) -> Option<String> {
    env::var(key).ok().filter(|v| !v.is_empty())
}

pub fn input(prompt: &str, default: &str, env_key: &str) -> String {
    if let Some(v) = env_val(env_key) {
        return v;
    }
    if yes_mode() {
        return default.to_string();
    }
    Input::with_theme(&ColorfulTheme::default())
        .with_prompt(prompt)
        .default(default.to_string())
        .allow_empty(true)
        .interact_text()
        .unwrap_or_else(|_| default.to_string())
}

/// Asks twice. None when it's allowed to be empty and was left empty.
pub fn password(prompt: &str, env_key: &str, allow_empty: bool) -> Option<String> {
    if let Some(v) = env_val(env_key) {
        return Some(v);
    }
    if yes_mode() {
        return None;
    }
    loop {
        let p = Password::with_theme(&ColorfulTheme::default())
            .with_prompt(prompt)
            .with_confirmation("  repeat", "  passwords didn't match")
            .allow_empty_password(allow_empty)
            .interact()
            .unwrap_or_default();
        if p.is_empty() && !allow_empty {
            println!("   password cannot be empty");
            continue;
        }
        return if p.is_empty() { None } else { Some(p) };
    }
}

/// From env, 1/y/yes/true means yes and anything else means no.
pub fn confirm(prompt: &str, default: bool, env_key: &str) -> bool {
    if let Some(v) = env_val(env_key) {
        let v = v.to_ascii_lowercase();
        return v == "1" || v == "y" || v == "yes" || v == "true";
    }
    if yes_mode() {
        return default;
    }
    Confirm::with_theme(&ColorfulTheme::default())
        .with_prompt(prompt)
        .default(default)
        .interact()
        .unwrap_or(default)
}

/// The env value can be a 1-based index or a case-insensitive substring of an item.
pub fn select(prompt: &str, items: &[String], default_idx: usize, env_key: &str) -> usize {
    if let Some(v) = env_val(env_key) {
        if let Ok(n) = v.parse::<usize>() {
            if n >= 1 && n <= items.len() {
                return n - 1;
            }
        }
        let low = v.to_ascii_lowercase();
        if let Some(i) = items.iter().position(|it| it.to_ascii_lowercase().contains(&low)) {
            return i;
        }
    }
    if yes_mode() {
        return default_idx.min(items.len().saturating_sub(1));
    }
    Select::with_theme(&ColorfulTheme::default())
        .with_prompt(prompt)
        .items(items)
        .default(default_idx.min(items.len().saturating_sub(1)))
        .interact()
        .unwrap_or(default_idx)
}
