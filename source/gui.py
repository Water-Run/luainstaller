"""
Graphical user interface for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides a simple Tkinter-based GUI that wraps
the luainstaller CLI commands.

:author: WaterRun
:email: linzhangrun49@gmail.com
:file: gui.py
:date: 2025-12-15
"""

import ctypes
import os
import shutil
import subprocess
import sys
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import NoReturn

from .engine import get_default_engine


VERSION = "2.0"
WINDOW_TITLE = "luainstaller-gui@waterrun"
WINDOW_WIDTH = 650
WINDOW_HEIGHT = 520
PROJECT_URL = "https://github.com/Water-Run/luainstaller"


def _enable_windows_dpi_awareness() -> None:
    """
    Enable DPI awareness on Windows for proper scaling.
    
    This should be called before creating any Tkinter windows.
    """
    if os.name != "nt":
        return

    try:
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except (AttributeError, OSError):
        try:
            ctypes.windll.user32.SetProcessDPIAware()
        except (AttributeError, OSError):
            ...


class LuaInstallerGUI:
    """
    GUI wrapper for luainstaller CLI.
    
    Provides a minimal interface for selecting entry Lua script
    and invoking the CLI build command via subprocess.
    """

    __slots__ = (
        "root",
        "entry_script_var",
        "output_path_var",
        "entry_script_entry",
        "output_path_entry",
        "log_text",
        "build_button",
        "engine_label",
        "_font_normal",
        "_font_bold",
        "_font_title",
        "_font_mono",
        "_cli_executable",
        "_default_engine",
    )

    def __init__(self, root: tk.Tk) -> None:
        """
        Initialize the GUI application.
        
        :param root: The Tkinter root window
        """
        self.root = root
        self.root.title(WINDOW_TITLE)
        self.root.resizable(False, False)

        self.entry_script_var = tk.StringVar()
        self.output_path_var = tk.StringVar()

        self._cli_executable = self._find_cli_executable()
        self._default_engine = get_default_engine()

        self._setup_styles()
        self._setup_ui()

        self.entry_script_var.trace_add("write", self._on_entry_changed)

    @staticmethod
    def _find_cli_executable() -> str:
        """
        Find the luainstaller-cli executable.
        
        :return: Path to the CLI executable
        :raises FileNotFoundError: If CLI executable is not found
        """
        cli_path = shutil.which("luainstaller-cli")
        if cli_path:
            return cli_path

        cli_path = shutil.which("luainstaller")
        if cli_path:
            return cli_path

        raise FileNotFoundError(
            "luainstaller-cli not found in PATH. "
            "Please ensure luainstaller is properly installed."
        )

    def _setup_styles(self) -> None:
        """Setup ttk styles for modern appearance."""
        style = ttk.Style()

        try:
            if os.name == "nt":
                available_themes = style.theme_names()
                for theme in ("vista", "winnative", "xpnative", "clam"):
                    if theme in available_themes:
                        style.theme_use(theme)
                        break
            else:
                available = style.theme_names()
                for theme in ("clam", "alt", "default"):
                    if theme in available:
                        style.theme_use(theme)
                        break
        except tk.TclError:
            ...

        if os.name == "nt":
            self._font_normal = ("Segoe UI", 9)
            self._font_bold = ("Segoe UI", 10, "bold")
            self._font_title = ("Segoe UI", 14, "bold")
            self._font_mono = ("Consolas", 9)
        else:
            self._font_normal = ("Sans", 9)
            self._font_bold = ("Sans", 10, "bold")
            self._font_title = ("Sans", 14, "bold")
            self._font_mono = ("Monospace", 9)

        style.configure("Title.TLabel", font=self._font_title)
        style.configure("Hint.TLabel", font=self._font_normal,
                        foreground="#666666")
        style.configure("Engine.TLabel", font=self._font_normal,
                        foreground="#0066cc")
        style.configure(
            "Link.TLabel",
            font=(self._font_normal[0], self._font_normal[1], "underline"),
            foreground="#0066cc",
        )
        style.configure("Build.TButton", font=self._font_bold,
                        padding=(20, 10))
        style.configure("TLabelframe.Label", font=self._font_normal)

        style.configure("TEntry", padding=5)
        style.configure("TButton", padding=5)

    def _setup_ui(self) -> None:
        """Setup the user interface components."""
        main_frame = ttk.Frame(self.root, padding=20)
        main_frame.pack(fill=tk.BOTH, expand=True)

        self._create_header(main_frame)
        self._create_engine_info(main_frame)
        self._create_input_section(main_frame)
        self._create_output_section(main_frame)
        self._create_log_section(main_frame)
        self._create_build_section(main_frame)
        self._create_footer(main_frame)

    def _create_header(self, parent: ttk.Frame) -> None:
        """
        Create the header section.
        
        :param parent: Parent frame
        """
        header_frame = ttk.Frame(parent)
        header_frame.pack(fill=tk.X, pady=(0, 10))

        ttk.Label(header_frame, text="luainstaller", style="Title.TLabel").pack(
            anchor=tk.W
        )

        ttk.Label(
            header_frame,
            text=(
                "GUI provides basic build functionality only. "
                "For full features (engine selection, etc.), use CLI or library."
            ),
            style="Hint.TLabel",
            wraplength=600,
        ).pack(anchor=tk.W, pady=(5, 0))

    def _create_engine_info(self, parent: ttk.Frame) -> None:
        """
        Create the engine information section.
        
        :param parent: Parent frame
        """
        engine_frame = ttk.Frame(parent)
        engine_frame.pack(fill=tk.X, pady=(0, 10))

        platform_name = "Windows" if os.name == "nt" else "Linux"

        self.engine_label = ttk.Label(
            engine_frame,
            text=f"Current Engine: {self._default_engine} ({platform_name})",
            style="Engine.TLabel",
        )
        self.engine_label.pack(anchor=tk.W)

    def _create_input_section(self, parent: ttk.Frame) -> None:
        """
        Create the entry script input section.
        
        :param parent: Parent frame
        """
        input_frame = ttk.LabelFrame(parent, text="Entry Script", padding=10)
        input_frame.pack(fill=tk.X, pady=(0, 10))

        entry_row = ttk.Frame(input_frame)
        entry_row.pack(fill=tk.X)

        self.entry_script_entry = ttk.Entry(
            entry_row, textvariable=self.entry_script_var, font=self._font_normal
        )
        self.entry_script_entry.pack(
            side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10)
        )

        ttk.Button(
            entry_row, text="Browse", command=self._browse_entry_script, width=10
        ).pack(side=tk.RIGHT)

    def _create_output_section(self, parent: ttk.Frame) -> None:
        """
        Create the output path display section.
        
        :param parent: Parent frame
        """
        output_frame = ttk.LabelFrame(
            parent, text="Output Path (auto-generated)", padding=10
        )
        output_frame.pack(fill=tk.X, pady=(0, 10))

        self.output_path_entry = ttk.Entry(
            output_frame,
            textvariable=self.output_path_var,
            state="readonly",
            font=self._font_normal,
        )
        self.output_path_entry.pack(fill=tk.X)

    def _create_log_section(self, parent: ttk.Frame) -> None:
        """
        Create the CLI output section.
        
        :param parent: Parent frame
        """
        log_frame = ttk.LabelFrame(parent, text="CLI Output", padding=10)
        log_frame.pack(fill=tk.BOTH, expand=True, pady=(0, 10))

        text_frame = ttk.Frame(log_frame)
        text_frame.pack(fill=tk.BOTH, expand=True)

        scrollbar = ttk.Scrollbar(text_frame, orient=tk.VERTICAL)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.log_text = tk.Text(
            text_frame,
            height=10,
            state=tk.DISABLED,
            wrap=tk.WORD,
            font=self._font_mono,
            bg="#fafafa" if os.name == "nt" else None,
            relief=tk.FLAT if os.name == "nt" else tk.SUNKEN,
            borderwidth=1,
        )
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scrollbar.config(command=self.log_text.yview)
        self.log_text.config(yscrollcommand=scrollbar.set)

    def _create_build_section(self, parent: ttk.Frame) -> None:
        """
        Create the build button section.
        
        :param parent: Parent frame
        """
        build_frame = ttk.Frame(parent)
        build_frame.pack(fill=tk.X, pady=(0, 10))

        self.build_button = ttk.Button(
            build_frame,
            text="Build Executable",
            command=self._run_build,
            style="Build.TButton",
        )
        self.build_button.pack(expand=True)

    def _create_footer(self, parent: ttk.Frame) -> None:
        """
        Create the footer with link.
        
        :param parent: Parent frame
        """
        footer_frame = ttk.Frame(parent)
        footer_frame.pack(fill=tk.X, side=tk.BOTTOM)

        ttk.Separator(footer_frame, orient=tk.HORIZONTAL).pack(
            fill=tk.X, pady=(0, 8))

        version_label = ttk.Label(
            footer_frame, text=f"v{VERSION}", style="Hint.TLabel"
        )
        version_label.pack(side=tk.LEFT)

        link_label = ttk.Label(
            footer_frame, text="GitHub", style="Link.TLabel", cursor="hand2"
        )
        link_label.pack(side=tk.RIGHT)
        link_label.bind("<Button-1>", lambda _: webbrowser.open(PROJECT_URL))

    def _log(self, message: str) -> None:
        """
        Append message to the log text widget.
        
        :param message: Message to append
        """
        self.log_text.config(state=tk.NORMAL)
        self.log_text.insert(tk.END, message)
        self.log_text.see(tk.END)
        self.log_text.config(state=tk.DISABLED)

    def _log_clear(self) -> None:
        """Clear the log text widget."""
        self.log_text.config(state=tk.NORMAL)
        self.log_text.delete("1.0", tk.END)
        self.log_text.config(state=tk.DISABLED)

    def _browse_entry_script(self) -> None:
        """Open file dialog to select entry script."""
        initial_dir = None
        if current := self.entry_script_var.get().strip():
            current_path = Path(current)
            if current_path.parent.exists():
                initial_dir = str(current_path.parent)

        filepath = filedialog.askopenfilename(
            title="Select Entry Lua Script",
            filetypes=[("Lua Scripts", "*.lua"), ("All Files", "*.*")],
            initialdir=initial_dir,
        )
        if filepath:
            self.entry_script_var.set(filepath)

    def _on_entry_changed(self, *_: object) -> None:
        """Handle entry script path change to auto-generate output path."""
        entry_script = self.entry_script_var.get().strip()

        if not entry_script:
            self.output_path_var.set("")
            return

        entry_path = Path(entry_script)

        if entry_path.suffix == ".lua":
            output_name = entry_path.stem + (".exe" if os.name == "nt" else "")
            output_path = Path.cwd() / output_name
            self.output_path_var.set(str(output_path))
        else:
            self.output_path_var.set("")

    def _validate_inputs(self) -> bool:
        """
        Validate user inputs before building.
        
        :return: True if all inputs are valid, False otherwise
        """
        entry_script = self.entry_script_var.get().strip()

        if not entry_script:
            messagebox.showerror("Error", "Please select an entry script.")
            return False

        entry_path = Path(entry_script)

        if not entry_path.exists():
            messagebox.showerror("Error", f"Script not found:\n{entry_script}")
            return False

        if entry_path.suffix != ".lua":
            messagebox.showerror("Error", "Entry script must be a .lua file.")
            return False

        if not self.output_path_var.get().strip():
            messagebox.showerror("Error", "Output path not generated.")
            return False

        return True

    def _run_build(self) -> None:
        """Run the CLI build command using luainstaller-cli."""
        if not self._validate_inputs():
            return

        entry_script = self.entry_script_var.get().strip()
        output_path = self.output_path_var.get().strip()

        cmd = [
            self._cli_executable,
            "build",
            entry_script,
            "-output",
            output_path,
            "--detail",
        ]

        self._log_clear()
        self._log(f"$ {' '.join(cmd)}\n\n")

        self.build_button.config(state=tk.DISABLED)
        self.root.update()

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                cwd=str(Path(entry_script).parent),
            )

            if result.stdout:
                self._log(result.stdout)
            if result.stderr:
                self._log(result.stderr)

            if result.returncode == 0:
                self._log("\n[Build completed successfully]")
                messagebox.showinfo(
                    "Success", f"Build completed!\n\nOutput: {output_path}"
                )
            else:
                self._log(
                    f"\n[Build failed with exit code {result.returncode}]")

        except FileNotFoundError:
            self._log(
                "[Error: luainstaller-cli not found. "
                "Please ensure luainstaller is properly installed.]\n"
            )
        except OSError as e:
            self._log(f"[Error executing command: {e}]\n")

        finally:
            self.build_button.config(state=tk.NORMAL)


def run_gui() -> None:
    """Run the luainstaller GUI application."""
    _enable_windows_dpi_awareness()

    root = tk.Tk()

    try:
        if os.name == "nt":
            root.iconbitmap(default="")
    except tk.TclError:
        ...

    if os.name == "nt":
        root.tk.call("tk", "scaling", 1.0)

    try:
        _ = LuaInstallerGUI(root)
    except FileNotFoundError as e:
        messagebox.showerror("Error", str(e))
        sys.exit(1)

    root.update_idletasks()
    x = (root.winfo_screenwidth() // 2) - (WINDOW_WIDTH // 2)
    y = (root.winfo_screenheight() // 2) - (WINDOW_HEIGHT // 2)
    root.geometry(f"{WINDOW_WIDTH}x{WINDOW_HEIGHT}+{x}+{y}")

    root.mainloop()


def gui_main() -> NoReturn:
    """GUI entry point that runs the application."""
    run_gui()
    sys.exit(0)


if __name__ == "__main__":
    gui_main()
