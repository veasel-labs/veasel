module main

import json2

// These structs model the stable, text-only subset of ATIF emitted by Veasel.
// Token usage is only emitted when a provider adapter reported authoritative
// values; otherwise it is explicitly marked unavailable.
struct ATIFTrajectory {
	schema_version string = 'ATIF-v1.8'
	session_id     string
	agent          ATIFAgent
	steps          []ATIFStep
	final_metrics  map[string]json2.Any @[omitempty]
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
	usage  ProviderUsage
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
	return encode_atif_trace_with_outcome(session_id, version, model, steps, 'completed')
}

fn encode_atif_trace_with_outcome(session_id string, version string, model string, steps []ATIFStep, outcome string) !string {
	return encode_atif_trace_with_usage(session_id, version, model, steps, outcome, ProviderUsage{})
}

fn encode_atif_trace_with_usage(session_id string, version string, model string, steps []ATIFStep, outcome string, usage ProviderUsage) !string {
	if steps.len == 0 {
		return error('cannot export an empty ATIF trajectory')
	}
	if outcome !in ['completed', 'failed', 'cancelled'] {
		return error('invalid ATIF trajectory outcome')
	}
	mut metrics := map[string]json2.Any{}
	if usage.reported {
		// ATIF final_metrics has no total_tokens field; the total is the sum
		// of the two reported counts below.
		metrics['total_prompt_tokens'] = json2.Any(usage.input_tokens)
		metrics['total_completion_tokens'] = json2.Any(usage.output_tokens)
	}
	return json2.encode(ATIFTrajectory{
		session_id:    session_id
		agent:         ATIFAgent{
			version:    version
			model_name: model
		}
		steps:         steps
		final_metrics: metrics
		extra:         {
			'veasel_trace_schema': json2.Any('veasel-trace-v1')
			'outcome':             json2.Any(outcome)
			'token_usage':         json2.Any(if usage.reported { 'reported' } else { 'unavailable' })
			'cost':                json2.Any('unavailable')
		}
	})
}
