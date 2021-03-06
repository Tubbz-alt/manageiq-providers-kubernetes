module ManageIQ::Providers::Kubernetes::ContainerManager::StreamingRefreshMixin
  include Vmdb::Logging

  attr_accessor :ems, :initial, :resource_versions, :watch_streams, :watch_threads, :queue

  def after_initialize
    super

    self.ems = @emss.first
    setup_streaming_refresh if ems.supports_streaming_refresh?
  end

  def do_before_work_loop
    # If we're using streaming refresh skip queueing a full
    ems.supports_streaming_refresh? || super
  end

  def do_work
    ems.supports_streaming_refresh? ? do_work_streaming_refresh : super
  end

  def before_exit(_message, _exit_code)
    stop_watch_threads if ems.supports_streaming_refresh?
  end

  private

  def setup_streaming_refresh
    self.initial           = true
    self.queue             = Queue.new
    self.resource_versions = {}
    self.watch_streams     = Concurrent::Map.new
    self.watch_threads     = Concurrent::Map.new
  end

  def do_work_streaming_refresh
    if initial
      full_refresh
      start_watch_threads
    else
      ensure_watch_threads
      targeted_refresh
    end
  end

  def full_refresh
    _log.info("Running initial refresh...")
    inventory = refresh(
      collector_klass.new(ems, ems),
      parser_klass.new,
      persister_klass.new(ems)
    )
    _log.info("Running initial refresh...Complete")

    self.initial = false
    save_resource_versions(inventory)
  end

  def targeted_refresh
    notices = []
    notices << queue.pop until queue.empty?
    return if notices.empty?

    _log.info("Processing #{notices.count} Updates...")
    refresh(
      watches_collector_klass.new(ems, notices),
      parser_klass.new,
      targeted_persister_klass.new(ems)
    )
    _log.info("Processing #{notices.count} Updates...Complete")
  end

  def save_resource_versions(inventory)
    entity_types.each do |entity_type|
      resource_versions[entity_type] = inventory.collector.send(entity_type).resourceVersion
    end
  end

  def refresh(collector, parser, persister)
    inventory = ManageIQ::Providers::Kubernetes::Inventory.new(persister, collector, parser)

    inventory.parse
    inventory.persister.persist!

    inventory
  end

  def start_watch_threads
    _log.info("#{log_header} Starting watch threads...")

    entity_types.each do |entity_type|
      watch_threads[entity_type] = start_watch_thread(entity_type)
    end

    _log.info("#{log_header} Starting watch threads...Complete")
  end

  def ensure_watch_threads
    entity_types.each do |entity_type|
      next if watch_threads[entity_type].alive?

      _log.info("#{log_header} Restarting #{entity_type} watch thread")

      watch_threads[entity_type] = start_watch_thread(entity_type)
    end
  end

  def stop_watch_threads
    safe_log("#{log_header} Stopping watch threads...")

    # First call WatchStream#finish to forcibly terminate the loop, this
    # closes the HTTP connection and will cause the #each method to raise an
    # exception (until https://github.com/abonas/kubeclient/pull/315 is applied).
    watch_streams.each_value(&:finish)

    # Next loop through each thread and join them cleanly
    watch_threads.each_value { |thread| thread.join(10) }

    safe_log("#{log_header} Stopping watch threads...Complete")
  end

  def start_watch_thread(entity_type)
    Thread.new { watch_thread(entity_type) }
  end

  def watch_thread(entity_type)
    _log.info("#{log_header} #{entity_type} watch thread started")

    resource_version = resource_versions[entity_type] || "0"

    watch_stream = start_watch(entity_type, resource_version)
    watch_streams[entity_type] = watch_stream

    begin
      watch_stream.each do |notice|
        # Update the collection resourceVersion to be the most recent
        # object's resourceVersion so that if this watch has to be restarted
        # it will pick up where it left off.
        resource_version = notice.object.metadata.resourceVersion
        resource_versions[entity_type] = resource_version

        queue.push(notice)
      end
    rescue HTTP::ConnectionError
      # This is raised when #finish is called on a WatchStream
    end

    _log.info("#{log_header} #{entity_type} watch thread exiting")
  rescue => err
    _log.log_backtrace(err)
  end

  def start_watch(entity_type, resource_version = "0")
    watch_method = "watch_#{entity_type}"
    connection_for_entity(entity_type).send(watch_method, :resource_version => resource_version)
  end

  def connection_for_entity(_entity_type)
    kubernetes_connection
  end

  def kubernetes_connection
    @kubernetes_connection ||= ems.connect(:service => "kubernetes")
  end

  def kubernetes_entity_types
    %w(
      namespaces
      pods
    )
  end

  def entity_types
    kubernetes_entity_types
  end

  def log_header
    "EMS [#{ems.name}], ID: [#{ems.id}]"
  end

  def collector_klass
    ems.class.parent::Inventory::Collector::ContainerManager
  end

  def watches_collector_klass
    ems.class.parent::Inventory::Collector::Watches
  end

  def parser_klass
    ems.class.parent::Inventory::Parser::ContainerManager
  end

  def watches_parser_klass
    ems.class.parent::Inventory::Parser::Watches
  end

  def persister_klass
    ems.class.parent::Inventory::Persister::ContainerManager
  end

  def targeted_persister_klass
    ems.class.parent::Inventory::Persister::TargetCollection
  end
end
