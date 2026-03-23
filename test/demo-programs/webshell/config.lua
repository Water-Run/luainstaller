local config = {
    host            = os.getenv("RTERM_HOST") or "127.0.0.1",
    port            = os.getenv("RTERM_PORT") or "9090",

    password        = os.getenv("RTERM_PASSWORD") or "changeme_PLEASE",

    default_timeout = 30,
    min_timeout     = 1,
    max_timeout     = 300,

    shell           = "/bin/sh",
    work_dir        = nil,

    cors_origin     = "*",
}

return config
