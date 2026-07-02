//! Full-screen TUI installer (ratatui). One form screen with every setting,
//! Enter-to-edit, a confirm dialog, then a live progress view driven by the
//! engine running on a worker thread. Works on the Linux console (TERM=linux)
//! and over serial.

use crate::boot::Firmware;
use crate::disk::Disk;
use crate::engine::{self, Config, Ev, Payload};
use crossterm::event::{self, Event, KeyCode, KeyEventKind, KeyModifiers};
use crossterm::terminal::{disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen};
use ratatui::backend::CrosstermBackend;
use ratatui::layout::{Alignment, Constraint, Direction, Layout, Rect};
use ratatui::style::{Color, Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, Borders, Clear, Gauge, List, ListItem, Paragraph, Wrap};
use ratatui::Terminal;
use std::io;
use std::sync::mpsc;
use std::time::Duration;

const ACCENT: Color = Color::Magenta; // blueberry-ish

#[derive(Clone, Copy, PartialEq)]
enum Row {
    Disk,
    Bootloader,
    Keymap,
    Hostname,
    RootPw,
    UserName,
    UserPw,
    Swap,
    Luks,
    LuksPw,
    Install,
}
const ROWS: &[Row] = &[
    Row::Disk, Row::Bootloader, Row::Keymap, Row::Hostname, Row::RootPw,
    Row::UserName, Row::UserPw, Row::Swap, Row::Luks, Row::LuksPw, Row::Install,
];

struct Form {
    disks: Vec<Disk>,
    disk_idx: usize,
    fw_options: Vec<Firmware>,
    fw_idx: usize,
    km_idx: usize,
    hostname: String,
    root_pw: String,
    user_name: String,
    user_pw: String,
    swap: String,
    luks: bool,
    luks_pw: String,
    sel: usize,
    editing: Option<String>, // edit buffer when editing the selected row
    error: Option<String>,
}

enum Phase {
    Form,
    Confirm,
    Progress {
        rx: mpsc::Receiver<Msg>,
        steps_done: u32,
        total: u32,
        current: String,
        log: Vec<String>,
        result: Option<Result<(), String>>,
    },
}

enum Msg {
    Ev(Ev),
    Done(Result<(), String>),
}

/// Run the interactive TUI. Ok(true) = install finished (caller reboots).
pub fn run(payload: Payload, disks: Vec<Disk>, detected: Firmware) -> io::Result<bool> {
    let mut fw_options = Vec::new();
    if crate::boot::uefi_available(&payload.dir) {
        fw_options.push(Firmware::Uefi);
    }
    if crate::boot::bios_available(&payload.dir) {
        fw_options.push(Firmware::Bios);
    }
    if fw_options.is_empty() {
        fw_options.push(detected);
    }
    let fw_idx = fw_options.iter().position(|f| *f == detected).unwrap_or(0);

    let mut form = Form {
        disks,
        disk_idx: 0,
        fw_options,
        fw_idx,
        km_idx: 0,
        hostname: "blueberry".into(),
        root_pw: String::new(),
        user_name: String::new(),
        user_pw: String::new(),
        swap: "0".into(),
        luks: false,
        luks_pw: String::new(),
        sel: 0,
        editing: None,
        error: None,
    };

    enable_raw_mode()?;
    let mut stdout = io::stdout();
    crossterm::execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut term = Terminal::new(backend)?;
    term.clear()?;

    let mut phase = Phase::Form;
    let mut frame_n: u32 = 0;
    let mut installed_ok = false;

    'outer: loop {
        // Drain engine events when installing.
        if let Phase::Progress { rx, steps_done, current, log, result, .. } = &mut phase {
            while let Ok(m) = rx.try_recv() {
                match m {
                    Msg::Ev(Ev::Step(s)) => {
                        *steps_done += 1;
                        *current = s.clone();
                        log.push(format!(":: {s}"));
                    }
                    Msg::Ev(Ev::Log(s)) => log.push(s),
                    Msg::Done(r) => {
                        if r.is_ok() {
                            installed_ok = true;
                        }
                        *result = Some(r);
                    }
                }
                if log.len() > 400 {
                    log.drain(..100);
                }
            }
        }

        // Full redraw every ~5s: stray console writes (kernel printk) desync the
        // diff renderer; a periodic clear self-heals any ghost cells.
        frame_n += 1;
        if frame_n % 40 == 0 {
            term.clear()?;
        }
        term.draw(|f| draw(f, &payload, &form, &phase))?;

        if !event::poll(Duration::from_millis(120))? {
            continue;
        }
        let Event::Key(key) = event::read()? else { continue };
        if key.kind != KeyEventKind::Press {
            continue;
        }
        // Ctrl-C always exits (to the rescue shell).
        if key.code == KeyCode::Char('c') && key.modifiers.contains(KeyModifiers::CONTROL) {
            break 'outer;
        }

        match &mut phase {
            Phase::Form => {
                if let Some(buf) = &mut form.editing {
                    match key.code {
                        KeyCode::Enter => {
                            let v = form.editing.take().unwrap();
                            form.commit(v);
                        }
                        KeyCode::Esc => {
                            form.editing = None;
                        }
                        KeyCode::Backspace => {
                            buf.pop();
                        }
                        KeyCode::Char(c) => buf.push(c),
                        _ => {}
                    }
                    continue;
                }
                match key.code {
                    KeyCode::Up => form.sel = form.sel.saturating_sub(1),
                    KeyCode::Down => form.sel = (form.sel + 1).min(ROWS.len() - 1),
                    KeyCode::Left | KeyCode::Right => form.cycle(key.code == KeyCode::Right),
                    KeyCode::Enter => match ROWS[form.sel] {
                        Row::Disk | Row::Bootloader | Row::Keymap => form.cycle(true),
                        Row::Luks => form.luks = !form.luks,
                        Row::Install => {
                            if let Some(e) = form.validate() {
                                form.error = Some(e);
                            } else {
                                form.error = None;
                                phase = Phase::Confirm;
                            }
                        }
                        _ => form.start_edit(),
                    },
                    KeyCode::Char(' ') if ROWS[form.sel] == Row::Luks => form.luks = !form.luks,
                    KeyCode::Char('q') => break 'outer,
                    _ => {}
                }
            }
            Phase::Confirm => match key.code {
                KeyCode::Enter | KeyCode::Char('y') | KeyCode::Char('Y') => {
                    let cfg = form.to_config();
                    let total = engine::total_steps(&cfg, &payload);
                    let (tx, rx) = mpsc::channel::<Msg>();
                    let pl = Payload {
                        dir: payload.dir.clone(),
                        profile: payload.profile.clone(),
                        name: payload.name.clone(),
                        manifest: payload.manifest.clone(),
                        overlay: payload.overlay,
                    };
                    std::thread::spawn(move || {
                        let txe = tx.clone();
                        let mut emit = move |e: Ev| {
                            let _ = txe.send(Msg::Ev(e));
                        };
                        let r = engine::run_install(&cfg, &pl, &mut emit);
                        let _ = tx.send(Msg::Done(r));
                    });
                    phase = Phase::Progress {
                        rx,
                        steps_done: 0,
                        total,
                        current: "Starting…".into(),
                        log: Vec::new(),
                        result: None,
                    };
                }
                KeyCode::Esc | KeyCode::Char('n') | KeyCode::Char('N') => phase = Phase::Form,
                _ => {}
            },
            Phase::Progress { result, .. } => {
                if let Some(r) = result {
                    match key.code {
                        KeyCode::Enter if r.is_ok() => break 'outer, // caller reboots
                        KeyCode::Char('q') => {
                            installed_ok = false;
                            break 'outer;
                        }
                        _ => {}
                    }
                }
            }
        }
    }

    disable_raw_mode()?;
    crossterm::execute!(term.backend_mut(), LeaveAlternateScreen)?;
    term.show_cursor()?;
    Ok(installed_ok)
}

impl Form {
    fn cycle(&mut self, fwd: bool) {
        match ROWS[self.sel] {
            Row::Disk if !self.disks.is_empty() => {
                let n = self.disks.len();
                self.disk_idx = (self.disk_idx + if fwd { 1 } else { n - 1 }) % n;
            }
            Row::Bootloader => {
                let n = self.fw_options.len();
                self.fw_idx = (self.fw_idx + if fwd { 1 } else { n - 1 }) % n;
            }
            Row::Keymap => {
                let n = engine::KEYMAPS.len();
                self.km_idx = (self.km_idx + if fwd { 1 } else { n - 1 }) % n;
                // apply immediately so the passwords you type match the layout
                let _ = crate::run::out(&["loadkeys", engine::KEYMAPS[self.km_idx].0]);
            }
            Row::Luks => self.luks = !self.luks,
            _ => {}
        }
    }

    fn start_edit(&mut self) {
        let cur = match ROWS[self.sel] {
            Row::Hostname => self.hostname.clone(),
            Row::UserName => self.user_name.clone(),
            Row::Swap => self.swap.clone(),
            // passwords start empty on edit
            Row::RootPw | Row::UserPw | Row::LuksPw => String::new(),
            _ => return,
        };
        self.editing = Some(cur);
    }

    fn commit(&mut self, v: String) {
        match ROWS[self.sel] {
            Row::Hostname => self.hostname = v,
            Row::RootPw => self.root_pw = v,
            Row::UserName => self.user_name = v,
            Row::UserPw => self.user_pw = v,
            Row::Swap => self.swap = v,
            Row::LuksPw => self.luks_pw = v,
            _ => {}
        }
    }

    fn validate(&self) -> Option<String> {
        if self.disks.is_empty() {
            return Some("no installable disks found".into());
        }
        if self.root_pw.is_empty() {
            return Some("set a root password first".into());
        }
        if self.luks && self.luks_pw.is_empty() {
            return Some("LUKS is enabled but has no passphrase".into());
        }
        if !self.user_name.is_empty() && self.user_pw.is_empty() {
            return Some(format!("set a password for user '{}'", self.user_name));
        }
        None
    }

    fn to_config(&self) -> Config {
        Config {
            disk_dev: self.disks[self.disk_idx].dev.clone(),
            firmware: self.fw_options[self.fw_idx],
            keymap: engine::KEYMAPS[self.km_idx].0.to_string(),
            hostname: self.hostname.clone(),
            root_pw: self.root_pw.clone(),
            user: if self.user_name.trim().is_empty() {
                None
            } else {
                Some((self.user_name.trim().to_string(), self.user_pw.clone()))
            },
            swap_gib: self.swap.trim().parse().unwrap_or(0),
            luks_pw: if self.luks { Some(self.luks_pw.clone()) } else { None },
            extra_pkgs: String::new(),
        }
    }
}

fn mask(s: &str) -> String {
    if s.is_empty() { "(not set)".into() } else { "•".repeat(s.len().min(16)) }
}

fn draw(f: &mut ratatui::Frame, payload: &Payload, form: &Form, phase: &Phase) {
    let area = f.area();
    let outer = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(8), Constraint::Length(2)])
        .split(area);

    // Header
    let title = format!(
        "  Blueberry Installer — {}{}",
        payload.name,
        if payload.manifest.is_some() { "  [online]" } else { "  [offline]" }
    );
    f.render_widget(
        Paragraph::new(title)
            .style(Style::default().fg(ACCENT).add_modifier(Modifier::BOLD))
            .block(Block::default().borders(Borders::BOTTOM).border_style(Style::default().fg(ACCENT))),
        outer[0],
    );

    match phase {
        Phase::Form | Phase::Confirm => draw_form(f, outer[1], form),
        Phase::Progress { steps_done, total, current, log, result, .. } => {
            draw_progress(f, outer[1], *steps_done, *total, current, log, result)
        }
    }

    // Footer
    let help = match phase {
        Phase::Form if form.editing.is_some() => "Enter apply · Esc cancel",
        Phase::Form => "↑/↓ move · Enter edit/toggle · ←/→ cycle · q quit · Ctrl-C shell",
        Phase::Confirm => "Enter/y install · Esc cancel",
        Phase::Progress { result: Some(Ok(())), .. } => "Enter reboot",
        Phase::Progress { result: Some(Err(_)), .. } => "q drop to shell",
        Phase::Progress { .. } => "installing — please wait (Ctrl-C aborts)",
    };
    f.render_widget(
        Paragraph::new(help).style(Style::default().fg(Color::DarkGray)),
        outer[2],
    );

    if matches!(phase, Phase::Confirm) {
        let d = &form.disks[form.disk_idx];
        let (kc, _, kl) = engine::KEYMAPS[form.km_idx];
        let msg = format!(
            "\n{}\n\n  Disk        {}  ({:.1} GiB)\n  Bootloader  GRUB — {}\n  Keyboard    {} ({})\n  Hostname    {}\n  User        {}\n  Swap        {} GiB\n  Encryption  {}\n\nEVERYTHING ON THE DISK WILL BE ERASED.\n\n[Enter] Install      [Esc] Go back",
            "Ready to install:",
            d.dev, d.gib(),
            engine::fw_name(form.fw_options[form.fw_idx]),
            kl, kc,
            form.hostname,
            if form.user_name.is_empty() { "(none)" } else { &form.user_name },
            form.swap,
            if form.luks { "LUKS2" } else { "no" },
        );
        popup(f, area, " Confirm installation ", &msg, Color::Red);
    }
}

fn draw_form(f: &mut ratatui::Frame, area: Rect, form: &Form) {
    let cols = Layout::default()
        .direction(Direction::Horizontal)
        .constraints([Constraint::Percentage(62), Constraint::Percentage(38)])
        .split(area);
    let area = cols[0];
    let items: Vec<ListItem> = ROWS
        .iter()
        .enumerate()
        .map(|(i, row)| {
            let sel = i == form.sel;
            let editing = sel && form.editing.is_some();
            let (label, value) = match row {
                Row::Disk => {
                    let v = if form.disks.is_empty() {
                        "NO DISKS FOUND".to_string()
                    } else {
                        let d = &form.disks[form.disk_idx];
                        format!("{}  {:.1} GiB  {}", d.dev, d.gib(), d.model)
                    };
                    ("Target disk", v)
                }
                Row::Bootloader => (
                    "Bootloader",
                    format!("GRUB — {}", engine::fw_name(form.fw_options[form.fw_idx])),
                ),
                Row::Keymap => {
                    let (c, _, l) = engine::KEYMAPS[form.km_idx];
                    ("Keyboard layout", format!("{l} ({c})"))
                }
                Row::Hostname => ("Hostname", form.hostname.clone()),
                Row::RootPw => ("Root password", mask(&form.root_pw)),
                Row::UserName => (
                    "Create user",
                    if form.user_name.is_empty() { "(none)".into() } else { form.user_name.clone() },
                ),
                Row::UserPw => ("User password", mask(&form.user_pw)),
                Row::Swap => ("Swapfile (GiB)", form.swap.clone()),
                Row::Luks => ("Encrypt (LUKS2)", if form.luks { "yes".into() } else { "no".into() }),
                Row::LuksPw => ("LUKS passphrase", mask(&form.luks_pw)),
                Row::Install => ("", "▶ Install".to_string()),
            };
            let value = if editing {
                let buf = form.editing.as_deref().unwrap_or("");
                let shown = match row {
                    Row::RootPw | Row::UserPw | Row::LuksPw => "•".repeat(buf.len()),
                    _ => buf.to_string(),
                };
                format!("{shown}▏")
            } else {
                value
            };
            let (lstyle, vstyle) = if sel {
                let s = Style::default().fg(Color::Black).bg(ACCENT).add_modifier(Modifier::BOLD);
                (s, s)
            } else if *row == Row::Install {
                let s = Style::default().fg(Color::Green).add_modifier(Modifier::BOLD);
                (s, s)
            } else {
                (
                    Style::default().fg(Color::Gray),
                    Style::default().fg(Color::Cyan),
                )
            };
            let line = if label.is_empty() {
                Line::from(Span::styled(format!("  {value}"), vstyle))
            } else {
                Line::from(vec![
                    Span::styled(format!("  {label:<18}"), lstyle),
                    Span::styled(value, vstyle),
                ])
            };
            ListItem::new(line)
        })
        .collect();

    let mut block = Block::default()
        .borders(Borders::ALL)
        .border_style(Style::default().fg(ACCENT))
        .title(" Setup ");
    if let Some(e) = &form.error {
        block = block
            .title_bottom(Line::from(Span::styled(
                format!(" {e} "),
                Style::default().fg(Color::White).bg(Color::Red),
            )));
    }
    f.render_widget(List::new(items).block(block), area);

    // Context help for the selected row.
    let info = match ROWS[form.sel] {
        Row::Disk => "The disk Blueberry is installed to.\n\nEverything on it is erased during the install. ←/→ cycles through the detected disks.",
        Row::Bootloader => "How the system boots.\n\nUEFI for modern machines (an EFI system partition is created), BIOS for legacy machines and simple VMs. The detected firmware is pre-selected.",
        Row::Keymap => "Console + desktop keyboard layout.\n\nApplies IMMEDIATELY in this installer (so the passwords you type match) and is saved to the installed system (console + desktop).",
        Row::Hostname => "This machine's network name.",
        Row::RootPw => "Password for the root (administrator) account. Required.",
        Row::UserName => "Optional everyday user account.\n\nIt is added to the wheel group, so it can use sudo.",
        Row::UserPw => "Password for the user account.",
        Row::Swap => "Size of the swapfile created at /swapfile. 0 disables swap.",
        Row::Luks => "Full-disk encryption (LUKS2) for the root filesystem.\n\nYou will type the passphrase at every boot.",
        Row::LuksPw => "The LUKS passphrase. Without it the data is unrecoverable.",
        Row::Install => "Review the summary and start the installation.",
    };
    f.render_widget(
        Paragraph::new(info)
            .wrap(Wrap { trim: true })
            .style(Style::default().fg(Color::Gray))
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(Color::DarkGray))
                    .title(" Help "),
            ),
        cols[1],
    );
}

fn draw_progress(
    f: &mut ratatui::Frame,
    area: Rect,
    done: u32,
    total: u32,
    current: &str,
    log: &[String],
    result: &Option<Result<(), String>>,
) {
    let chunks = Layout::default()
        .direction(Direction::Vertical)
        .constraints([Constraint::Length(3), Constraint::Min(4)])
        .split(area);

    let (label, ratio, color) = match result {
        Some(Ok(())) => ("Installation complete — press Enter to reboot".to_string(), 1.0, Color::Green),
        Some(Err(e)) => (format!("FAILED: {e}"), (done as f64 / total.max(1) as f64).min(1.0), Color::Red),
        None => (
            format!("[{done}/{total}] {current}"),
            (done as f64 / total.max(1) as f64).min(1.0),
            ACCENT,
        ),
    };
    f.render_widget(
        Gauge::default()
            .block(Block::default().borders(Borders::ALL).title(" Progress "))
            .gauge_style(Style::default().fg(color))
            .ratio(ratio)
            .label(label),
        chunks[0],
    );

    let h = chunks[1].height.saturating_sub(2) as usize;
    let tail: Vec<Line> = log
        .iter()
        .rev()
        .take(h)
        .rev()
        .map(|l| Line::from(l.as_str()))
        .collect();
    f.render_widget(
        Paragraph::new(tail)
            .wrap(Wrap { trim: true })
            .block(Block::default().borders(Borders::ALL).title(" Log ")),
        chunks[1],
    );
}

fn popup(f: &mut ratatui::Frame, area: Rect, title: &str, msg: &str, color: Color) {
    let w = 58.min(area.width.saturating_sub(4));
    let h = 18.min(area.height.saturating_sub(2));
    let rect = Rect::new(
        area.x + (area.width.saturating_sub(w)) / 2,
        area.y + (area.height.saturating_sub(h)) / 2,
        w,
        h,
    );
    f.render_widget(Clear, rect);
    f.render_widget(
        Paragraph::new(msg)
            .alignment(Alignment::Center)
            .wrap(Wrap { trim: true })
            .block(
                Block::default()
                    .borders(Borders::ALL)
                    .border_style(Style::default().fg(color).add_modifier(Modifier::BOLD))
                    .title(title),
            ),
        rect,
    );
}
