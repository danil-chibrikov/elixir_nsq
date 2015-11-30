defmodule NSQ.Producer do
  # ------------------------------------------------------- #
  # Directives                                              #
  # ------------------------------------------------------- #
  require Logger
  import NSQ.Protocol
  use GenServer

  # ------------------------------------------------------- #
  # Module Attributes                                       #
  # ------------------------------------------------------- #
  @initial_state %{
    topic: nil,
    channel: nil,
    conn_sup_pid: nil,
    config: nil,
    shared_conn_info_agent: nil
  }

  # ------------------------------------------------------- #
  # Behaviour Implementation                                #
  # ------------------------------------------------------- #
  def init(pro_state) do
    {:ok, conn_sup_pid} = NSQ.ConnectionSupervisor.start_link
    pro_state = %{pro_state | conn_sup_pid: conn_sup_pid}

    {:ok, shared_conn_info_agent} = Agent.start_link(fn -> %{} end)
    pro_state = %{pro_state | shared_conn_info_agent: shared_conn_info_agent}

    {:ok, _pro_state} = connect_to_nsqds(pro_state.config.nsqds, self, pro_state)
  end

  def handle_call({:pub, data}, _from, pro_state) do
    do_pub(pro_state.topic, data, pro_state)
  end

  def handle_call({:pub, topic, data}, _from, pro_state) do
    do_pub(pro_state.topic, data, pro_state)
  end

  def handle_call({:mpub, data}, _from, pro_state) do
    do_mpub(pro_state.topic, data, pro_state)
  end

  def handle_call({:mpub, topic, data}, _from, pro_state) do
    do_mpub(topic, data, pro_state)
  end

  def handle_call(:state, _from, state) do
    {:reply, state, state}
  end

  # ------------------------------------------------------- #
  # API Definitions                                         #
  # ------------------------------------------------------- #
  def new(config, topic) do
    NSQ.ProducerSupervisor.start_link(config, topic)
  end

  def start_link(config, topic) do
    {:ok, config} = NSQ.Config.validate(config || %NSQ.Config{})
    {:ok, config} = NSQ.Config.normalize(config)
    unless is_valid_topic_name?(topic), do: raise "Invalid topic name #{topic}"
    state = %{@initial_state | topic: topic, config: config}
    GenServer.start_link(__MODULE__, state)
  end

  def get_connections(pro_state) when is_map(pro_state) do
    children = Supervisor.which_children(pro_state.conn_sup_pid)
    Enum.map children, fn({child_id, pid, _, _}) -> {child_id, pid} end
  end

  def get_connections(pro, pro_state \\ nil) when is_pid(pro) do
    pro_state = pro_state || get_state(pro)
    Supervisor.which_children(pro_state.conn_sup_pid)
  end

  def random_connection_pid(pro, pro_state \\ nil) do
    pro_state = pro_state || get_state(pro)
    {_child_id, pid} = Enum.random(get_connections(pro_state))
    pid
  end

  def connect_to_nsqds(nsqds, pro, pro_state \\ nil) do
    pro_state = pro_state || get_state(pro)
    new_conns = Enum.map nsqds, fn(nsqd) ->
      {:ok, conn} = NSQ.ConnectionSupervisor.start_child(
        pro, nsqd, pro_state
      )
      {nsqd, conn}
    end
    {:ok, pro_state}
  end

  def get_state(producer) do
    GenServer.call(producer, :state)
  end

  @doc """
  Publish data to whatever topic is the default.
  """
  def pub(sup_pid, data) do
    {:ok, _resp} = GenServer.call(get(sup_pid), {:pub, data})
  end

  @doc """
  Publish data to a specific topic.
  """
  def pub(sup_pid, topic, data) do
    {:ok, _resp} = GenServer.call(get(sup_pid), {:pub, topic, data})
  end

  @doc """
  Publish data to whatever topic is the default.
  """
  def mpub(sup_pid, data) do
    GenServer.call(get(sup_pid), {:mpub, data})
  end

  @doc """
  Publish data to a specific topic.
  """
  def mpub(sup_pid, topic, data) do
    {:ok, _resp} = GenServer.call(get(sup_pid), {:mpub, topic, data})
  end

  # The end-user will be targeting the supervisor, but it's the producer that
  # can actually handle the command.
  def get(sup_pid) do
    children = Supervisor.which_children(sup_pid)
    child = Enum.find(children, fn({kind, pid, _, _}) -> kind == NSQ.Producer end)
    {_, pid, _, _} = child
    pid
  end

  # Used to DRY up handle_call({:pub, ...).
  defp do_pub(topic, data, pro_state) do
    conn_pid = random_connection_pid(self, pro_state)
    {:ok, resp} = NSQ.Connection.cmd(conn_pid, {:pub, topic, data})
    {:reply, {:ok, resp}, pro_state}
  end

  # Used to DRY up handle_call({:mpub, ...).
  defp do_mpub(topic, data, pro_state) do
    conn_pid = random_connection_pid(self, pro_state)
    {:ok, resp} = NSQ.Connection.cmd(conn_pid, {:mpub, topic, data})
    {:reply, {:ok, resp}, pro_state}
  end
end
