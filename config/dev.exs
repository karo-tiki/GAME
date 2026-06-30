import Config

config :bomb_party_quiz, BombPartyQuizWeb.Endpoint,

  http: [ip: {127, 0, 0, 1}],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "yJ0aX9mMJptlTAMmwR0XTSIbLAG+zQVnjckA2nyGuy7ZRoaMRO3cCbyKTXwgb2ja",
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:bomb_party_quiz, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:bomb_party_quiz, ~w(--watch)]}
  ]


config :bomb_party_quiz, BombPartyQuizWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      # Static assets, except user uploads
      ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
      # Gettext translations
      ~r"priv/gettext/.*\.po$"E,
      # Router, Controllers, LiveViews and LiveComponents
      ~r"lib/bomb_party_quiz_web/router\.ex$"E,
      ~r"lib/bomb_party_quiz_web/(controllers|live|components)/.*\.(ex|heex)$"E
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :bomb_party_quiz, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true

config :swoosh, :api_client, false
