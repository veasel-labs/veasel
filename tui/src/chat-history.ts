export type ChatTurn = {
  id: number
  session_id: string
  role: "user" | "assistant"
  content: string
  created_at: string
}

export function mergeChatTurns(existing: ChatTurn[], incoming: ChatTurn[]) {
  const turns = new Map<number, ChatTurn>()
  for (const message of [...existing, ...incoming]) turns.set(message.id, message)
  return [...turns.values()].sort((left, right) => left.id - right.id)
}

export function pageMayHaveOlder(messages: ChatTurn[], pageSize: number) {
  return messages.length === pageSize
}
