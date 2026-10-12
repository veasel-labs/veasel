module main

import json2

// These structs model the stable, text-only subset of ATIF emitted by Veasel.
// Provider token usage is intentionally omitted until the provider adapters
// expose authoritative usage values.
struct ATIFTrajectory {
	schema_version string = 'ATIF-v1.8'
	session_id     string
	agent          ATIFAgent
	steps          []ATIFStep
	extra          map[string]json2.Any
}

struct ATIFAgent {
	name       string = 'Veasel Code'
	version    string
	model_name string
	extra      map[string]json2.Any
}

struct ATIFStep {
	step_id    int
	source     string
	model_name string @[omitempty]
	message    string
	tool_calls []ATIFToolCall @[omitempty]
mut:
	observation ?ATIFObservation @[omitempty]
}

struct ATIFToolCall {
	tool_call_id  string
	function_name string
	arguments     map[string]json2.Any
}

struct ATIFObservation {
	results []ATIFObservationResult
}

struct ATIFObservationResult {
	source_call_id string
	content        string
}

struct AgentTraceResult {
	output CompletionOutput
	steps  []ATIFStep
}

fn atif_tool_call(call ProviderToolCall) !ATIFToolCall {
	parsed_arguments := json2.decode[map[string]json2.Any](call.function.arguments) or {
		return error('provider returned invalid JSON tool arguments')
	}
	return ATIFToolCall{
		tool_call_id:  call.id
		function_name: call.function.name
		arguments:     parsed_arguments
	}
}

fn encode_atif_trace(session_id string, version string, model string, steps []ATIFStep) !string {
	if steps.len == 0 {
		return error('cannot export an empty ATIF trajectory')
	}
	return json2.encode(ATIFTrajectory{
		session_id: session_id
		agent:      ATIFAgent{
			version:    version
			model_name: model
		}
		steps:      steps
		extra:      {
			'veasel_trace_schema': json2.Any('veasel-trace-v1')
			'token_usage':         json2.Any('unavailable')
			'cost':                json2.Any('unavailable')
		}
	})
}
