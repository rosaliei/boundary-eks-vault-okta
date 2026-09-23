{
  "title": "Boundary workers - ${asg}",
  "description": "Sessions, worker health, scaling monitors and the event log. Managed by autoscaling/datadog.",
  "layout_type": "ordered",
  "reflow_type": "fixed",
  "widgets": [
    {
      "definition": {
        "type": "query_value", "title": "Active sessions (all workers)", "precision": 0, "autoscale": false,
        "requests": [{ "response_format": "scalar", "queries": [
          { "data_source": "metrics", "name": "q", "query": "sum:boundary.worker.active_sessions{asg:${asg}}", "aggregator": "last" }
        ], "formulas": [{ "formula": "q" }] }]
      },
      "layout": { "x": 0, "y": 0, "width": 3, "height": 2 }
    },
    {
      "definition": {
        "type": "query_value", "title": "Avg sessions per worker", "precision": 1, "autoscale": false,
        "requests": [{ "response_format": "scalar", "queries": [
          { "data_source": "metrics", "name": "q", "query": "avg:boundary.worker.active_sessions{asg:${asg}}", "aggregator": "last" }
        ], "formulas": [{ "formula": "q" }],
        "conditional_formats": [
          { "comparator": ">", "value": ${out_threshold}, "palette": "white_on_red" },
          { "comparator": "<", "value": ${in_threshold}, "palette": "white_on_yellow" },
          { "comparator": ">=", "value": ${in_threshold}, "palette": "white_on_green" }
        ] }]
      },
      "layout": { "x": 3, "y": 0, "width": 3, "height": 2 }
    },
    {
      "definition": {
        "type": "manage_status", "title": "Scaling monitors", "display_format": "countsAndList", "color_preference": "text",
        "hide_zero_counts": true, "show_last_triggered": true, "sort": "status,asc", "summary_type": "monitors",
        "query": "tag:(service:boundary-worker)"
      },
      "layout": { "x": 6, "y": 0, "width": 6, "height": 2 }
    },
    {
      "definition": {
        "type": "timeseries", "title": "Sessions per worker", "show_legend": true, "legend_layout": "auto",
        "requests": [{ "response_format": "timeseries", "display_type": "line", "queries": [
          { "data_source": "metrics", "name": "q", "query": "avg:boundary.worker.active_sessions{asg:${asg}} by {worker_name}" }
        ], "formulas": [{ "formula": "q" }] }],
        "markers": [
          { "value": "y = ${out_threshold}", "display_type": "error dashed", "label": "scale out" },
          { "value": "y = ${in_threshold}", "display_type": "warning dashed", "label": "scale in" }
        ]
      },
      "layout": { "x": 0, "y": 2, "width": 12, "height": 3 }
    },
    {
      "definition": {
        "type": "check_status", "title": "Worker health (/health)", "check": "boundary.worker.health",
        "grouping": "cluster", "group_by": ["host"], "tags": ["asg:${asg}"]
      },
      "layout": { "x": 0, "y": 5, "width": 3, "height": 2 }
    },
    {
      "definition": {
        "type": "timeseries", "title": "Session events / min (cloudevents log)", "show_legend": false,
        "requests": [{ "response_format": "timeseries", "display_type": "bars", "queries": [
          { "data_source": "logs", "name": "q", "search": { "query": "source:boundary @data.event_type:session*" },
            "indexes": ["*"], "compute": { "aggregation": "count" }, "group_by": [] }
        ], "formulas": [{ "formula": "q" }] }]
      },
      "layout": { "x": 3, "y": 5, "width": 5, "height": 2 }
    },
    {
      "definition": {
        "type": "timeseries", "title": "EC2 CPU per worker", "show_legend": false,
        "requests": [{ "response_format": "timeseries", "display_type": "line", "queries": [
          { "data_source": "metrics", "name": "q", "query": "avg:system.cpu.user{asg:${asg}} by {host}" }
        ], "formulas": [{ "formula": "q" }] }]
      },
      "layout": { "x": 8, "y": 5, "width": 4, "height": 2 }
    },
    {
      "definition": {
        "type": "log_stream", "title": "Boundary worker events", "query": "source:boundary",
        "columns": ["host", "service", "@data.event_type"], "show_date_column": true, "show_message_column": true,
        "message_display": "inline", "sort": { "column": "time", "order": "desc" }
      },
      "layout": { "x": 0, "y": 7, "width": 12, "height": 3 }
    }
  ]
}
