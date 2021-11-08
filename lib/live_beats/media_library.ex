defmodule LiveBeats.MediaLibrary do
  @moduledoc """
  The MediaLibrary context.
  """

  require Logger
  import Ecto.Query, warn: false
  alias LiveBeats.{Repo, MP3Stat, Accounts}
  alias LiveBeats.MediaLibrary.{Song, Genre}
  alias Ecto.{Multi, Changeset}

  @pubsub LiveBeats.PubSub

  defdelegate stopped?(song), to: Song
  defdelegate playing?(song), to: Song
  defdelegate paused?(song), to: Song

  def subscribe(%Accounts.User{} = user) do
    Phoenix.PubSub.subscribe(@pubsub, topic(user.id))
  end

  def local_filepath(filename_uuid) when is_binary(filename_uuid) do
    Path.join("priv/uploads/songs", filename_uuid)
  end

  def play_song(%Song{id: id}), do: play_song(id)

  def play_song(id) do
    song = get_song!(id)

    played_at =
      cond do
        playing?(song) ->
          song.played_at

        paused?(song) ->
          elapsed = DateTime.diff(song.paused_at, song.played_at, :second)
          DateTime.add(DateTime.utc_now(), -elapsed)

        true ->
          DateTime.utc_now()
      end

    changeset =
      Changeset.change(song, %{
        played_at: DateTime.truncate(played_at, :second),
        status: :playing
      })

    stopped_query =
      from s in Song,
        where: s.user_id == ^song.user_id and s.status == :playing,
        update: [set: [status: :stopped]]

    {:ok, %{now_playing: new_song}} =
      Multi.new()
      |> Multi.update_all(:now_stopped, fn _ -> stopped_query end, [])
      |> Multi.update(:now_playing, changeset)
      |> Repo.transaction()

    elapsed = elapsed_playback(new_song)
    Phoenix.PubSub.broadcast!(@pubsub, topic(song.user_id), {:play, song, %{elapsed: elapsed}})
  end

  def pause_song(%Song{} = song) do
    now = DateTime.truncate(DateTime.utc_now(), :second)
    set = [status: :paused, paused_at: now]
    pause_query = from(s in Song, where: s.id == ^song.id, update: [set: ^set])

    stopped_query =
      from s in Song,
        where: s.user_id == ^song.user_id and s.status in [:playing, :paused],
        update: [set: [status: :stopped]]

    {:ok, _} =
      Multi.new()
      |> Multi.update_all(:now_stopped, fn _ -> stopped_query end, [])
      |> Multi.update_all(:now_paused, fn _ -> pause_query end, [])
      |> Repo.transaction()

    Phoenix.PubSub.broadcast!(@pubsub, topic(song.user_id), {:pause, song})
  end

  defp topic(user_id), do: "room:#{user_id}"

  def store_mp3(%Song{} = song, tmp_path) do
    File.mkdir_p!(Path.dirname(song.mp3_filepath))
    File.cp!(tmp_path, song.mp3_filepath)
  end

  def put_stats(%Ecto.Changeset{} = changeset, %MP3Stat{} = stat) do
    Ecto.Changeset.put_change(changeset, :duration, stat.duration)
  end

  def import_songs(%Accounts.User{} = user, changesets, consume_file)
      when is_map(changesets) and is_function(consume_file, 2) do
    multi =
      Enum.reduce(changesets, Ecto.Multi.new(), fn {ref, chset}, acc ->
        chset =
          chset
          |> Song.put_user(user)
          |> Song.put_mp3_path()

        Ecto.Multi.insert(acc, {:song, ref}, chset)
      end)

    case LiveBeats.Repo.transaction(multi) do
      {:ok, results} ->
        {:ok,
         results
         |> Enum.filter(&match?({{:song, _ref}, _}, &1))
         |> Enum.map(fn {{:song, ref}, song} ->
           consume_file.(ref, fn tmp_path -> store_mp3(song, tmp_path) end)
           {ref, song}
         end)
         |> Enum.into(%{})}

      {:error, _failed_op, _failed_val, _changes} ->
        {:error, :invalid}
    end
  end

  def parse_file_name(name) do
    case Regex.split(~r/[-–]/, Path.rootname(name), parts: 2) do
      [title] -> %{title: String.trim(title), artist: nil}
      [title, artist] -> %{title: String.trim(title), artist: String.trim(artist)}
    end
  end

  def create_genre(attrs \\ %{}) do
    %Genre{}
    |> Genre.changeset(attrs)
    |> Repo.insert()
  end

  def list_genres do
    Repo.all(Genre, order_by: [asc: :title])
  end

  def list_songs(limit \\ 100) do
    Repo.all(from s in Song, limit: ^limit, order_by: [asc: s.inserted_at, asc: s.id])
  end

  def get_current_active_song(user_id) do
    Repo.one(from s in Song, where: s.user_id == ^user_id and s.status in [:playing, :paused])
  end

  def elapsed_playback(%Song{} = song) do
    cond do
      playing?(song) ->
        start_seconds = song.played_at |> DateTime.to_unix()
        System.os_time(:second) - start_seconds

      paused?(song) ->
        DateTime.diff(song.paused_at, song.played_at, :second)

      stopped?(song) ->
        0
    end
  end

  def get_song!(id), do: Repo.get!(Song, id)

  def create_song(attrs \\ %{}) do
    %Song{}
    |> Song.changeset(attrs)
    |> Repo.insert()
  end

  def update_song(%Song{} = song, attrs) do
    song
    |> Song.changeset(attrs)
    |> Repo.update()
  end

  def delete_song(%Song{} = song) do
    case File.rm(song.mp3_filepath) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info(
          "unable to delete song #{song.id} at #{song.mp3_filepath}, got: #{inspect(reason)}"
        )
    end

    Repo.delete(song)
  end

  def change_song(song_or_changeset, attrs \\ %{}) do
    song_or_changeset
    |> recycle_changeset()
    |> Song.changeset(attrs)
  end

  defp recycle_changeset(%Ecto.Changeset{} = changeset) do
    Map.merge(changeset, %{action: nil, errors: [], valid?: true})
  end

  defp recycle_changeset(%{} = other), do: other
end