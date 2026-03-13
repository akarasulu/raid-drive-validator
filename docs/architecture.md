# Architecture

This project uses a thin bin/lib split. The tmux runner handles discovery, planning, and orchestration. The single-drive worker performs the destructive tests and writes reports/state files. The dashboard reads state and report data without touching the drives directly.
