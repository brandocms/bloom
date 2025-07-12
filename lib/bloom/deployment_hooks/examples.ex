defmodule Bloom.DeploymentHooks.Examples do
  @moduledoc """
  Example deployment hooks demonstrating common integration patterns.

  These hooks show how to integrate with external systems during deployments:
  - Slack notifications
  - Metrics collection
  - External service health checks
  - Cache warming
  """

  defmodule SlackNotifier do
    @moduledoc """
    Example hook that sends deployment notifications to Slack.
    """

    @behaviour Bloom.DeploymentHooks.Behaviour

    require Logger

    @impl true
    def execute(context) do
      webhook_url = Application.get_env(:bloom, :slack_webhook_url)

      if webhook_url do
        case send_slack_notification(webhook_url, context) do
          :ok ->
            Logger.info("Slack notification sent for deployment #{context.id}")
            :ok

          {:error, reason} ->
            Logger.warning("Failed to send Slack notification: #{inspect(reason)}")
            # Don't fail deployment for notification failures
            :ok
        end
      else
        Logger.debug("No Slack webhook configured, skipping notification")
        :ok
      end
    end

    @impl true
    def info do
      %{
        name: "Slack Notifier",
        description: "Sends deployment notifications to Slack",
        version: "1.0.0",
        author: "Bloom Team",
        phases: [:pre_deployment, :post_deployment, :on_failure]
      }
    end

    defp send_slack_notification(webhook_url, context) do
      message = format_slack_message(context)

      # Use a simple HTTP request without HTTPoison dependency
      case make_http_request(webhook_url, Jason.encode!(message)) do
        {:ok, 200} -> :ok
        {:ok, status} -> {:error, "HTTP #{status}"}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ -> {:error, :http_client_unavailable}
    end

    defp format_slack_message(context) do
      status_emoji =
        case Map.get(context, :phase, :unknown) do
          :pre_deployment -> ":rocket:"
          :post_deployment -> ":white_check_mark:"
          :on_failure -> ":x:"
          _ -> ":information_source:"
        end

      %{
        text: "#{status_emoji} Deployment #{context.id}",
        attachments: [
          %{
            color: get_color_for_phase(Map.get(context, :phase)),
            fields: [
              %{title: "Version", value: context.target_version, short: true},
              %{title: "Started", value: context.started_at, short: true}
            ]
          }
        ]
      }
    end

    defp get_color_for_phase(:pre_deployment), do: "warning"
    defp get_color_for_phase(:post_deployment), do: "good"
    defp get_color_for_phase(:on_failure), do: "danger"
    defp get_color_for_phase(_), do: "warning"

    defp make_http_request(url, body) do
      # Simple HTTP POST using :httpc (built into Erlang)
      case :httpc.request(
             :post,
             {String.to_charlist(url), [], ~c"application/json", String.to_charlist(body)},
             [],
             []
           ) do
        {:ok, {{_, status_code, _}, _headers, _body}} -> {:ok, status_code}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ -> {:error, :http_unavailable}
    end
  end

  defmodule MetricsCollector do
    @moduledoc """
    Example hook that collects deployment metrics.
    """

    @behaviour Bloom.DeploymentHooks.Behaviour

    require Logger

    @impl true
    def execute(context) do
      phase = Map.get(context, :phase, :unknown)

      # Record deployment event
      record_deployment_metric(phase, context)

      # Update deployment duration if this is the end
      if phase == :post_deployment do
        record_deployment_duration(context)
      end

      Logger.debug("Recorded deployment metrics for #{context.id}")
      :ok
    end

    @impl true
    def info do
      %{
        name: "Metrics Collector",
        description: "Collects deployment timing and success metrics",
        version: "1.0.0",
        author: "Bloom Team",
        phases: [:pre_deployment, :post_deployment, :on_failure]
      }
    end

    defp record_deployment_metric(phase, context) do
      # This would integrate with your metrics system (Prometheus, DataDog, etc.)
      Logger.info(
        "METRIC: deployment.#{phase} version=#{context.target_version} deployment_id=#{context.id}"
      )
    end

    defp record_deployment_duration(context) do
      started_at = DateTime.from_iso8601(context.started_at)

      case started_at do
        {:ok, start_time, _offset} ->
          duration = DateTime.diff(DateTime.utc_now(), start_time, :millisecond)

          Logger.info(
            "METRIC: deployment.duration value=#{duration}ms deployment_id=#{context.id}"
          )

        _ ->
          Logger.warning("Could not calculate deployment duration for #{context.id}")
      end
    end
  end

  defmodule HealthChecker do
    @moduledoc """
    Example hook that performs external health checks.
    """

    @behaviour Bloom.DeploymentHooks.Behaviour

    require Logger

    @impl true
    def execute(context) do
      health_urls = Application.get_env(:bloom, :external_health_check_urls, [])

      if length(health_urls) > 0 do
        case check_external_services(health_urls) do
          :ok ->
            Logger.info("External health checks passed for deployment #{context.id}")
            :ok

          {:error, failed_services} ->
            Logger.error("External health checks failed: #{inspect(failed_services)}")
            {:error, "External services not healthy: #{Enum.join(failed_services, ", ")}"}
        end
      else
        Logger.debug("No external health check URLs configured")
        :ok
      end
    end

    @impl true
    def info do
      %{
        name: "External Health Checker",
        description: "Checks external service health before and after deployment",
        version: "1.0.0",
        author: "Bloom Team",
        phases: [:pre_deployment, :post_deployment]
      }
    end

    defp check_external_services(urls) do
      results = Enum.map(urls, &check_service_health/1)

      failed_services =
        results
        |> Enum.filter(&match?({:error, _}, &1))
        |> Enum.map(fn {:error, url} -> url end)

      if length(failed_services) == 0 do
        :ok
      else
        {:error, failed_services}
      end
    end

    defp check_service_health(url) do
      case make_http_get_request(url, 5000) do
        {:ok, status} when status in 200..299 ->
          :ok

        {:ok, _status} ->
          {:error, url}

        {:error, _reason} ->
          {:error, url}
      end
    rescue
      _ -> {:error, url}
    end

    defp make_http_get_request(url, timeout) do
      case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, timeout}], []) do
        {:ok, {{_, status_code, _}, _headers, _body}} -> {:ok, status_code}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ -> {:error, :http_unavailable}
    end
  end

  defmodule CacheWarmer do
    @moduledoc """
    Example hook that warms application caches after deployment.
    """

    @behaviour Bloom.DeploymentHooks.Behaviour

    require Logger

    @impl true
    def execute(context) do
      cache_warm_urls = Application.get_env(:bloom, :cache_warm_urls, [])

      if length(cache_warm_urls) > 0 do
        Logger.info("Warming caches for deployment #{context.id}")

        # Warm caches in parallel
        tasks =
          Enum.map(cache_warm_urls, fn url ->
            Task.async(fn -> warm_cache(url) end)
          end)

        # Wait for all cache warming to complete (with timeout)
        results = Task.yield_many(tasks, 30_000)

        # Shutdown any tasks that didn't complete
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

        # Check results
        failed_urls =
          results
          |> Enum.filter(fn
            {_task, {:ok, {:error, _url}}} -> true
            # timeout
            {_task, nil} -> true
            _ -> false
          end)
          |> Enum.map(fn
            {_task, {:ok, {:error, url}}} -> url
            {_task, nil} -> "timeout"
          end)

        if length(failed_urls) == 0 do
          Logger.info("Cache warming completed successfully")
          :ok
        else
          Logger.warning("Some cache warming failed: #{inspect(failed_urls)}")
          # Don't fail deployment for cache warming issues
          :ok
        end
      else
        Logger.debug("No cache warming URLs configured")
        :ok
      end
    end

    @impl true
    def info do
      %{
        name: "Cache Warmer",
        description: "Warms application caches after successful deployment",
        version: "1.0.0",
        author: "Bloom Team",
        phases: [:post_deployment]
      }
    end

    defp warm_cache(url) do
      case make_http_get_request(url, 10_000) do
        {:ok, status} when status in 200..299 ->
          :ok

        {:ok, _status} ->
          {:error, url}

        {:error, _reason} ->
          {:error, url}
      end
    rescue
      _ -> {:error, url}
    end

    defp make_http_get_request(url, timeout) do
      case :httpc.request(:get, {String.to_charlist(url), []}, [{:timeout, timeout}], []) do
        {:ok, {{_, status_code, _}, _headers, _body}} -> {:ok, status_code}
        {:error, reason} -> {:error, reason}
      end
    rescue
      _ -> {:error, :http_unavailable}
    end
  end
end
