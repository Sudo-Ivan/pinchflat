defmodule Pinchflat.Metadata.SourceMetadataStorageWorkerTest do
  use Pinchflat.DataCase

  import Pinchflat.SourcesFixtures
  import Pinchflat.ProfilesFixtures

  alias Pinchflat.Sources
  alias Pinchflat.Metadata.MetadataFileHelpers
  alias Pinchflat.Metadata.SourceMetadataStorageWorker

  describe "kickoff_with_task/1" do
    test "enqueues a new worker for the source" do
      source = source_fixture()

      assert {:ok, _} = SourceMetadataStorageWorker.kickoff_with_task(source)

      assert_enqueued(worker: SourceMetadataStorageWorker, args: %{"id" => source.id})
    end

    test "creates a new task for the source" do
      source = source_fixture()

      assert {:ok, task} = SourceMetadataStorageWorker.kickoff_with_task(source)

      assert task.source_id == source.id
    end
  end

  describe "perform/1" do
    test "won't call itself in an infinite loop" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, "{}"}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})

      assert [] = all_enqueued(worker: SourceMetadataStorageWorker)
    end

    test "does not blow up if the record doesn't exist" do
      assert :ok = perform_job(SourceMetadataStorageWorker, %{id: 0})
    end
  end

  describe "perform/1 when testing attribute updates" do
    test "the source description is saved" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture(%{description: nil})

      refute source.description
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.description == "This is a test file for Pinchflat"
    end
  end

  describe "perform/1 when testing metadata storage" do
    test "sets metadata location for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, "{}"}
      end)

      source = Repo.preload(source_fixture(), :metadata)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.metadata.metadata_filepath

      File.rm!(source.metadata.metadata_filepath)
    end

    test "fetches and stores returned metadata for source" do
      source = source_fixture()
      file_contents = Phoenix.json_library().encode!(%{"title" => "test"})

      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, file_contents}
      end)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)
      {:ok, metadata} = MetadataFileHelpers.read_compressed_metadata(source.metadata.metadata_filepath)

      assert metadata == %{"title" => "test"}
    end

    test "sets metadata image location for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert source.metadata.fanart_filepath
      assert source.metadata.poster_filepath
      assert source.metadata.banner_filepath

      Sources.delete_source(source, delete_files: true)
    end

    test "stores metadata images for source" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl -> {:ok, source_details_return_fixture()}
        _url, :get_source_metadata, _opts, _ot, _addl -> {:ok, render_metadata(:channel_source_metadata)}
      end)

      source = source_fixture()

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.preload(Repo.reload(source), :metadata)

      assert File.exists?(source.metadata.fanart_filepath)
      assert File.exists?(source.metadata.poster_filepath)
      assert File.exists?(source.metadata.banner_filepath)

      Sources.delete_source(source, delete_files: true)
    end
  end

  describe "perform/1 when testing source image downloading" do
    test "downloads and stores source images" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:convert_thumbnails, "jpg"} in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.fanart_filepath
      assert source.poster_filepath
      assert source.banner_filepath

      assert File.exists?(source.fanart_filepath)
      assert File.exists?(source.poster_filepath)
      assert File.exists?(source.banner_filepath)

      Sources.delete_source(source, delete_files: true)
    end

    test "calls one set of yt-dlp metadata opts for channels" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:playlist_items, 0} in opts
          assert :write_all_thumbnails in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, collection_type: :channel)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "calls another set of yt-dlp metadata opts for playlists" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, opts, _ot, _addl ->
          assert {:playlist_items, 1} in opts
          assert :write_thumbnail in opts

          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, collection_type: :playlist)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not store source images if the profile is not set to" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: false})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.fanart_filepath
      refute source.poster_filepath
      refute source.banner_filepath
    end

    test "does not store source images if the series directory cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.fanart_filepath
      refute source.poster_filepath
      refute source.banner_filepath
    end

    test "sets use_cookies if the source uses cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :all_operations)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :when_needed)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source does not use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, render_metadata(:channel_source_metadata)}
      end)

      profile = media_profile_fixture(%{download_source_images: true})
      source = source_fixture(media_profile_id: profile.id, cookie_behaviour: :disabled)

      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end
  end

  describe "perform/1 when determining the series_directory" do
    test "sets the series directory based on the returned media filepath" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.series_directory
    end

    test "does not set the series directory if it cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.series_directory
    end

    test "sets use_cookies if the source is set to use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, true} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :all_operations})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source uses cookies when needed" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :when_needed})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end

    test "does not set use_cookies if the source is not set to use cookies" do
      expect(YtDlpRunnerMock, :run, 2, fn
        _url, :get_source_details, _opts, _ot, addl ->
          assert {:use_cookies, false} in addl
          {:ok, source_details_return_fixture()}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      source = source_fixture(%{series_directory: nil, cookie_behaviour: :disabled})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
    end
  end

  describe "perform/1 when storing the series NFO" do
    test "stores the NFO if specified" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: true})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      assert source.nfo_filepath
      assert source.nfo_filepath == Path.join([source.series_directory, "tvshow.nfo"])
      assert File.exists?(source.nfo_filepath)

      File.rm!(source.nfo_filepath)
    end

    test "does not store the NFO if not specified" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "Season 1", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: false})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.nfo_filepath
    end

    test "does not store the NFO if the series directory cannot be determined" do
      stub(YtDlpRunnerMock, :run, fn
        _url, :get_source_details, _opts, _ot, _addl ->
          filename = Path.join([Application.get_env(:pinchflat, :media_directory), "foo", "bar.mp4"])

          {:ok, source_details_return_fixture(%{filename: filename})}

        _url, :get_source_metadata, _opts, _ot, _addl ->
          {:ok, "{}"}
      end)

      profile = media_profile_fixture(%{download_nfo: true})
      source = source_fixture(%{nfo_filepath: nil, media_profile_id: profile.id})
      perform_job(SourceMetadataStorageWorker, %{id: source.id})
      source = Repo.reload(source)

      refute source.nfo_filepath
    end
  end
end
