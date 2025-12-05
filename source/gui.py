"""
Graphical user interface for luainstaller.
https://github.com/Water-Run/luainstaller

This module provides a simple Tkinter-based GUI for building
Lua scripts into standalone executables.

:author: WaterRun
:email: linzhangrun49@gmail.com
:file: gui.py
:date: 2025-12-05
"""

import os
import sys
import threading
import tkinter as tk
import webbrowser
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import NoReturn

from .dependency_analyzer import analyze_dependencies
from .engine import compile_lua_script, get_environment_status
from .exceptions import LuaInstallerException
from .logger import log_error, log_success


VERSION = "1.0"
WINDOW_TITLE = "luainstaller-gui@waterrun"
WINDOW_WIDTH = 520
WINDOW_HEIGHT = 320
PROJECT_URL = "https://github.com/Water-Run/luainstallers/tree/main/luainstaller"


class LuaInstallerGUI:
    """
    Main GUI application class for luainstaller.
    
    Provides a minimal interface for selecting entry Lua script
    and building the executable. Output path is auto-generated.
    """
    
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
        self.status_var = tk.StringVar(value="Ready")
        self.is_building = False
        
        self._setup_styles()
        self._setup_ui()
        self._check_environment()
        
        self.entry_script_var.trace_add("write", self._on_entry_changed)
    
    def _setup_styles(self) -> None:
        """Setup ttk styles for modern appearance."""
        style = ttk.Style()
        
        try:
            if os.name == "nt":
                style.theme_use("vista")
            else:
                style.theme_use("clam")
        except tk.TclError:
            ...
        
        style.configure("Title.TLabel", font=("Segoe UI", 14, "bold") if os.name == "nt" else ("Sans", 14, "bold"))
        style.configure("Hint.TLabel", font=("Segoe UI", 9) if os.name == "nt" else ("Sans", 9), foreground="#666666")
        style.configure("Status.TLabel", font=("Segoe UI", 9) if os.name == "nt" else ("Sans", 9))
        style.configure("Link.TLabel", font=("Segoe UI", 9, "underline") if os.name == "nt" else ("Sans", 9, "underline"), foreground="#0066cc")
        style.configure("Build.TButton", font=("Segoe UI", 10, "bold") if os.name == "nt" else ("Sans", 10, "bold"), padding=(20, 10))
    
    def _setup_ui(self) -> None:
        """Setup the user interface components."""
        main_frame = ttk.Frame(self.root, padding=20)
        main_frame.pack(fill=tk.BOTH, expand=True)
        
        self._create_header(main_frame)
        self._create_input_section(main_frame)
        self._create_output_section(main_frame)
        self._create_build_section(main_frame)
        self._create_status_bar(main_frame)
    
    def _create_header(self, parent: ttk.Frame) -> None:
        """Create the header section with title and hint."""
        header_frame = ttk.Frame(parent)
        header_frame.pack(fill=tk.X, pady=(0, 15))
        
        ttk.Label(
            header_frame,
            text="luainstaller",
            style="Title.TLabel"
        ).pack(anchor=tk.W)
        
        ttk.Label(
            header_frame,
            text="GUI provides basic build functionality only. For full features, use CLI or library.",
            style="Hint.TLabel",
            wraplength=480
        ).pack(anchor=tk.W, pady=(5, 0))
    
    def _create_input_section(self, parent: ttk.Frame) -> None:
        """Create the entry script input section."""
        input_frame = ttk.LabelFrame(parent, text="Entry Script", padding=10)
        input_frame.pack(fill=tk.X, pady=(0, 10))
        
        entry_row = ttk.Frame(input_frame)
        entry_row.pack(fill=tk.X)
        
        self.entry_script_entry = ttk.Entry(entry_row, textvariable=self.entry_script_var, width=50)
        self.entry_script_entry.pack(side=tk.LEFT, fill=tk.X, expand=True, padx=(0, 10))
        
        ttk.Button(entry_row, text="Browse", command=self._browse_entry_script, width=10).pack(side=tk.RIGHT)
    
    def _create_output_section(self, parent: ttk.Frame) -> None:
        """Create the output path display section."""
        output_frame = ttk.LabelFrame(parent, text="Output Path (auto-generated)", padding=10)
        output_frame.pack(fill=tk.X, pady=(0, 15))
        
        self.output_path_entry = ttk.Entry(output_frame, textvariable=self.output_path_var, state="readonly", width=60)
        self.output_path_entry.pack(fill=tk.X)
    
    def _create_build_section(self, parent: ttk.Frame) -> None:
        """Create the build button section."""
        build_frame = ttk.Frame(parent)
        build_frame.pack(fill=tk.X, pady=(0, 15))
        
        self.build_button = ttk.Button(
            build_frame,
            text="Build Executable",
            command=self._start_build,
            style="Build.TButton"
        )
        self.build_button.pack(expand=True)
    
    def _create_status_bar(self, parent: ttk.Frame) -> None:
        """Create the status bar."""
        status_frame = ttk.Frame(parent)
        status_frame.pack(fill=tk.X, side=tk.BOTTOM)
        
        ttk.Separator(status_frame, orient=tk.HORIZONTAL).pack(fill=tk.X, pady=(0, 8))
        
        bottom_row = ttk.Frame(status_frame)
        bottom_row.pack(fill=tk.X)
        
        self.status_label = ttk.Label(bottom_row, textvariable=self.status_var, style="Status.TLabel")
        self.status_label.pack(side=tk.LEFT)
        
        link_label = ttk.Label(bottom_row, text="GitHub", style="Link.TLabel", cursor="hand2")
        link_label.pack(side=tk.RIGHT)
        link_label.bind("<Button-1>", lambda _: webbrowser.open(PROJECT_URL))
    
    def _check_environment(self) -> None:
        """Check compilation environment and update status."""
        status = get_environment_status()
        
        if not all(status.values()):
            missing = [tool for tool, available in status.items() if not available]
            self.status_var.set(f"Warning: Missing tools: {', '.join(missing)}")
    
    def _browse_entry_script(self) -> None:
        """Open file dialog to select entry script."""
        if filepath := filedialog.askopenfilename(
            title="Select Entry Lua Script",
            filetypes=[("Lua Scripts", "*.lua"), ("All Files", "*.*")]
        ):
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
    
    def _set_status(self, message: str) -> None:
        """Set the status bar message."""
        self.status_var.set(message)
    
    def _set_building(self, building: bool) -> None:
        """Set the building state and update UI accordingly."""
        self.is_building = building
        state = "disabled" if building else "normal"
        
        self.build_button.configure(state=state)
        self.entry_script_entry.configure(state=state)
    
    def _validate_entry_script(self) -> Path | None:
        """Validate the entry script path."""
        entry_script = self.entry_script_var.get().strip()
        
        if not entry_script:
            messagebox.showerror("Error", "Please select an entry script.")
            return None
        
        entry_path = Path(entry_script)
        
        if not entry_path.exists():
            messagebox.showerror("Error", f"Script not found:\n{entry_script}")
            return None
        
        if entry_path.suffix != ".lua":
            messagebox.showerror("Error", "Entry script must be a .lua file.")
            return None
        
        return entry_path
    
    def _start_build(self) -> None:
        """Start the build process in a background thread."""
        if (entry_path := self._validate_entry_script()) is None:
            return
        
        output_path = self.output_path_var.get().strip()
        
        if not output_path:
            messagebox.showerror("Error", "Output path not generated.")
            return
        
        self._set_status("Building...")
        self._set_building(True)
        
        def do_build() -> None:
            try:
                dependencies = analyze_dependencies(str(entry_path))
                
                result_path = compile_lua_script(
                    str(entry_path),
                    dependencies,
                    output=output_path,
                    verbose=False
                )
                
                log_success("gui", "build", f"Built {entry_path.name} -> {Path(result_path).name}")
                
                self.root.after(0, lambda: self._set_status("Build successful"))
                self.root.after(0, lambda: messagebox.showinfo(
                    "Success",
                    f"Build successful!\n\nOutput:\n{result_path}"
                ))
                
            except LuaInstallerException as e:
                log_error("gui", "build", f"Failed: {e.message}")
                self.root.after(0, lambda: self._set_status("Build failed"))
                self.root.after(0, lambda: messagebox.showerror("Build Failed", e.message))
                
            except Exception as e:
                log_error("gui", "build", f"Unexpected error: {e}")
                self.root.after(0, lambda: self._set_status("Build failed"))
                self.root.after(0, lambda: messagebox.showerror("Error", f"Unexpected error:\n{e}"))
                
            finally:
                self.root.after(0, lambda: self._set_building(False))
        
        threading.Thread(target=do_build, daemon=True).start()


def run_gui() -> None:
    """Run the luainstaller GUI application."""
    root = tk.Tk()
    
    try:
        if os.name == "nt":
            root.iconbitmap(default="")
    except tk.TclError:
        ...
    
    _ = LuaInstallerGUI(root)
    
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