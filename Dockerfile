FROM hexpm/elixir:1.16.3-erlang-26.2.5-alpine-3.19 AS build

RUN apk add --no-cache build-base git
WORKDIR /app

ENV MIX_ENV=prod

COPY mix.exs .
COPY config config
RUN mix local.hex --force && mix local.rebar --force && mix deps.get --only prod

COPY lib lib
COPY priv priv
RUN mix compile

RUN mix release

FROM alpine:3.19 AS app
RUN apk add --no-cache openssl ncurses-libs
WORKDIR /app

COPY --from=build /app/_build/prod/rel/beam_gate ./

ENV PHX_SERVER=true
ENV PORT=4000
ENV HTTPS_PORT=4443

EXPOSE 4000 4443
CMD ["bin/beam_gate", "start"]
