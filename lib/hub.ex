defmodule Hub do
  @moduledoc """
  Pub-sub hub

  Subscription is done with a pattern.

  Example:

    Hub.subscribe("global", %{count: count} when count > 42)
    Hub.publish("global", %{count: 45, message: "You rock!"})
  """

  alias Hub.Tracker

  @type subscribe_options :: [subscribe_option]
  @type subscribe_option :: {:pid, pid} | {:count, count} | {:multi, boolean}
  @type count :: pos_integer | :infinity
  @type pattern :: any
  @type channel :: String.t

  @tracker_topic_prefix "Hub.subscribers."

  defmodule Subscriber do
    @moduledoc """
    State for a single subscriber
    """

    @type t :: %__MODULE__{}

    defstruct [
      channel: nil,
      pid: nil,
      pattern: nil,
      count: nil,
      multi: nil
    ]

    def new(channel, pid, pattern, count, multi) do
      %__MODULE__{channel: channel, pid: pid, pattern: pattern, count: count, multi: multi}
    end
  end

  @doc """
  Convenience macro for subscribing without the need to unquote the pattern.

  example:

    Hub.subscribe("global", %{count: count} when count > 42)
  """
  defmacro subscribe(channel, pattern, options \\ []) do
    quote do
      {bind_quoted, options} = unquote(options) |> Keyword.pop(:bind_quoted, [])
      quoted_pattern = unquote(Macro.escape(pattern)) |> Hub.replace_pins(bind_quoted)

      Hub.subscribe_quoted(unquote(channel), quoted_pattern, options)
    end
  end

  @doc """
  Subscribes to the quoted pattern in the given channel

  example:

    Hub.subscribe("global", quote do: %{count: count} when count > 42)
  """
  @spec subscribe_quoted(channel, pattern, subscribe_options) :: :ok | {:error, reason :: String.t}
  def subscribe_quoted(channel, quoted_pattern, options \\ []) do
    map_options = options |> Enum.into(%{})
    do_subscribe_quoted(channel, quoted_pattern, map_options)
  end

  defp do_subscribe_quoted(_channel, quoted_pattern, %{multi: true}) when not is_list(quoted_pattern) do
    {:error, "Must subscribe with a list of patterns when using multi: true"}
  end
  defp do_subscribe_quoted(channel, quoted_pattern, options) do
    pid = options |> Map.get(:pid, self())
    count = options |> Map.get(:count, :infinity)
    multi = options |> Map.get(:multi, :false)

    subscriber = Subscriber.new(channel, pid, quoted_pattern, count, multi)

    topic = tracker_topic(channel)
    key = presence_key(subscriber)
    meta = %{subscriber: subscriber}

    pid
    |> Tracker.track(topic, key, meta)
    |> case do
      {:ok, _} ->
        :ok
      {:error, {:already_tracked, ^pid, ^topic, ^key}} ->
        {:ok, _} = Tracker.update(pid, topic, key, meta)
        :ok
    end
  end

  @doc """
  Publishes the term to all subscribers that matches it
  Returns the number of subscribers that got the message
  """
  @spec publish(channel, any) :: non_neg_integer
  def publish(channel, term) do
    channel
    |> subscribers
    |> Enum.filter(&publish_to_subscriber?(term, &1))
    |> Enum.map(&publish_to_subscriber(term, &1))
    |> length
  end

  @doc """
  Gets a list of all subscribers to a channel
  """
  @spec subscribers(channel) :: [Subscriber.t]
  def subscribers(channel) do
    channel
    |> tracker_topic
    |> Tracker.list
    |> Enum.map(fn {_key, %{subscriber: subscriber}} -> subscriber end)
  end

  defp publish_to_subscriber?(term, %{multi: true} = subscriber) do
    subscriber.pattern
    |> Enum.any?(&pattern_match?(&1, term))
  end
  defp publish_to_subscriber?(term, subscriber) do
    pattern_match?(subscriber.pattern, term)
  end

  defp publish_to_subscriber(term, subscriber) do
    update_subscriber(subscriber)
    send(subscriber.pid, term)
  end

  defp update_subscriber(%{count: :infinity}) do
    :ok
  end
  defp update_subscriber(%{count: 1, pid: pid, channel: channel} = subscriber) do
    Tracker.untrack(pid, tracker_topic(channel), presence_key(subscriber))
  end
  defp update_subscriber(%{count: count, pid: pid, channel: channel} = subscriber) when count > 1 do
    subscriber = %{subscriber | count: count - 1}
    Tracker.update(pid, tracker_topic(channel), presence_key(subscriber), %{subscriber: subscriber})
  end

  defp presence_key(%{pid: pid, pattern: pattern, multi: multi}) do
    {pid, pattern, multi} |> inspect
  end

  defp pattern_match?(pattern, term) do
    quoted_term = Macro.escape(term)

    ast = quote do
      case unquote(quoted_term) do
        unquote(pattern) -> true
        _ -> false
      end
    end

    {result, _} = Code.eval_quoted(ast)
    result
  end

  defp tracker_topic(channel) when is_binary(channel) do
    @tracker_topic_prefix <> channel
  end

  @doc false
  def replace_pins(ast, [] = _binding) do
    ast
  end
  def replace_pins(ast, bindings) do
    {ast, _acc} = Macro.traverse(
      ast,
      nil,
      fn ast, _acc ->
        ast = traverse_pin(ast, bindings)
        {ast, nil}
      end,
      fn ast, _acc -> {ast, nil} end
    )
    ast
  end

  def traverse_pin({:^, _, [{name, _, atom}]} = term, bindings) when is_atom(atom) do
    case Keyword.fetch(bindings, name) do
      {:ok, value} -> Macro.escape(value)
      :error -> term
    end
  end
  def traverse_pin(ast, _bindings) do
    ast
  end
end
