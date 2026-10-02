FROM elixir:1.20.4-otp-29-slim@sha256:3898ffe18d695e770239e4b342dc6b83136f52da0a37df2298083c03068cfd4e
LABEL org.acropolis.atheum.worker_spec="supplier-set-active-v1"
WORKDIR /app
COPY lib/atheum/core.ex lib/atheum/wire.ex /app/atheum/
COPY lib/atheum/worker/protocol.ex /app/atheum/worker/
COPY worker/main.exs /app/main.exs
USER 65534:65534
ENV HOME=/tmp ERL_CRASH_DUMP=/tmp/erl_crash.dump ELIXIR_ERL_OPTIONS="+S 1:1 +A 1 +SDcpu 1 +SDio 1"
ENTRYPOINT ["elixir", "-r", "/app/atheum/wire.ex", "-r", "/app/atheum/core.ex", "-r", "/app/atheum/worker/protocol.ex", "/app/main.exs"]
