defmodule Pinchflat.YtDlp.YtDlpCommandRunner do
  @moduledoc """
  A behaviour for running CLI commands against a downloader backend (yt-dlp).

  Used so we can implement Mox for testing without actually running the
  yt-dlp command.
  """

  @callback run(binary(), atom(), keyword(), binary()) :: {:ok, binary()} | {:error, binary(), integer()}
  @callback run(binary(), atom(), keyword(), binary(), keyword()) :: {:ok, binary()} | {:error, binary(), integer()}
  @callback version() :: {:ok, binary()} | {:error, binary()}
  @callback update() :: {:ok, binary()} | {:error, binary()}
end
