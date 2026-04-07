import { createCliRenderer } from "@opentui/core"
import { createRoot, useKeyboard, useTerminalDimensions } from "@opentui/react"
import { useEffect, useMemo, useRef, useState } from "react"

type ConfigResponse = {
  assistantName: string
  userName: string
  approvalMode: string
  debug: boolean
}

type TelegramRemoteControlStatus = {
  enabled: boolean
  pollingEnabled: boolean
  autoApproveTools: boolean
  hasBotToken: boolean
  botUsername: string | null
  approvedChatID: number | null
  approvedUserID: number | null
  linking: boolean
}

type RemoteControlStatus = {
  telegram: TelegramRemoteControlStatus
}

type SessionRecord = {
  id: number
  title: string
  createdAt: string
}

type SessionMessage = {
  role: string
  content: string
}

type ToolCallSummary = {
  name: string
  argumentsJSON: string
  approved: boolean
}

type StreamEvent = {
  type: string
  sessionID: number
  message?: SessionMessage | null
  toolCall?: ToolCallSummary | null
  error?: string | null
}

const API_BASE = process.env.APFELCLAW_API_BASE ?? "http://127.0.0.1:4242"
const WS_BASE = API_BASE.replace(/^http/, "ws")
const TRANSCRIPT_LABEL_WIDTH = 14

async function sleep(ms: number) {
  await new Promise((resolve) => setTimeout(resolve, ms))
}

async function readErrorMessage(response: Response) {
  const body = await response.text()
  const compact = body.trim()

  if (!compact) {
    return `Request failed (${response.status} ${response.statusText})`
  }

  try {
    const parsed = JSON.parse(compact) as { reason?: string; error?: string; message?: string }
    const message = parsed.reason ?? parsed.error ?? parsed.message
    if (message) return message
  } catch {
    // Fall back to raw response text when the server did not return JSON.
  }

  return compact
}

async function requireOK(response: Response) {
  if (!response.ok) {
    throw new Error(await readErrorMessage(response))
  }

  return response
}

function formatSingleLine(text: string, width: number) {
  const safeWidth = Math.max(width, 1)
  const compact = text.replace(/\s+/g, " ").trim()

  if (compact.length <= safeWidth) {
    return compact.padEnd(safeWidth, " ")
  }

  if (safeWidth === 1) {
    return "…"
  }

  return `${compact.slice(0, safeWidth - 1)}…`
}

function labelForRole(role: string, config: ConfigResponse | null) {
  switch (role) {
    case "user":
      return config?.userName ?? "You"
    case "assistant":
      return config?.assistantName ?? "Apfelclaw"
    case "tool":
      return "Tool"
    default:
      return role
  }
}

function roleColor(role: string) {
  switch (role) {
    case "user":
      return "#8ec5ff"
    case "assistant":
      return "#ffe58f"
    case "tool":
      return "#8ff5cb"
    default:
      return "#d7deea"
  }
}

type AppProps = {
  shutdown: () => void
}

function formatConfigSummary(config: ConfigResponse) {
  return [
    `assistantName: ${config.assistantName}`,
    `userName: ${config.userName}`,
    `approvalMode: ${config.approvalMode}`,
    `debug: ${config.debug}`,
  ].join("\n")
}

function parseConfigSetCommand(content: string) {
  const match = content.match(/^\/config\s+set\s+(assistantName|userName|approvalMode|debug)\s+(.+)$/)
  if (!match) return null

  const field = match[1] as keyof ConfigResponse
  return {
    field,
    value: field === "debug" ? match[2].trim().toLowerCase() : match[2].trim(),
  }
}

function parseRemoteControlCommand(content: string) {
  const trimmed = content.trim()

  if (trimmed === "/remotecontrol") {
    return { action: "show" as const }
  }

  if (trimmed === "/remotecontrol status telegram") {
    return { action: "status" as const }
  }

  if (trimmed === "/remotecontrol disable telegram") {
    return { action: "disable" as const }
  }

  if (trimmed === "/remotecontrol reset telegram") {
    return { action: "reset" as const }
  }

  const setupMatch = trimmed.match(/^\/remotecontrol\s+setup\s+telegram\s+(.+)$/)
  if (setupMatch) {
    return {
      action: "setup" as const,
      botToken: setupMatch[1].trim(),
    }
  }

  return null
}

function readServerVersion(response: Response) {
  return response.headers.get("server")?.trim() ?? null
}

function formatReconnectHint(status: string) {
  return `${status} · use /new to retry`
}

function formatTelegramRemoteStatus(status: TelegramRemoteControlStatus) {
  const lines = [
    "Remote control provider: telegram",
    `enabled: ${status.enabled}`,
    `pollingEnabled: ${status.pollingEnabled}`,
    `autoApproveTools: ${status.autoApproveTools}`,
    `hasBotToken: ${status.hasBotToken}`,
    `botUsername: ${status.botUsername ?? "(unverified)"}`,
    `approvedChatID: ${status.approvedChatID ?? "(not linked)"}`,
    `approvedUserID: ${status.approvedUserID ?? "(not linked)"}`,
    `linking: ${status.linking}`,
  ]

  if (status.botUsername && status.linking) {
    lines.push(`Next step: send a private message to @${status.botUsername}, then run /remotecontrol status telegram.`)
  }

  return lines.join("\n")
}

function formatRemoteControlSummary(status: RemoteControlStatus) {
  return [
    formatTelegramRemoteStatus(status.telegram),
    "",
    "Commands:",
    "/remotecontrol",
    "/remotecontrol status telegram",
    "/remotecontrol setup telegram <botToken>",
    "/remotecontrol disable telegram",
    "/remotecontrol reset telegram",
  ].join("\n")
}

function splitMessageLines(content: string) {
  return content.replace(/\r\n?/g, "\n").split("\n")
}

function App({ shutdown }: AppProps) {
  const [config, setConfig] = useState<ConfigResponse | null>(null)
  const [session, setSession] = useState<SessionRecord | null>(null)
  const [messages, setMessages] = useState<SessionMessage[]>([])
  const [input, setInput] = useState("")
  const [status, setStatus] = useState("Connecting to apfelclaw-server…")
  const [serverVersion, setServerVersion] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const socketRef = useRef<WebSocket | null>(null)
  const requestAbortRef = useRef<AbortController | null>(null)
  const openSessionSeqRef = useRef(0)
  const mountedRef = useRef(true)
  const terminal = useTerminalDimensions()
  const terminalWidth = terminal?.width ?? 80
  const terminalHeight = terminal?.height ?? 24

  const title = useMemo(() => {
    const appLabel = config?.assistantName ?? "Apfelclaw"
    const headerLabel = serverVersion ? `${appLabel} (${serverVersion})` : appLabel
    if (!config) return headerLabel
    const debugLabel = config.debug ? "debug:on" : "debug:off"
    return `${headerLabel} · ${config.approvalMode} · ${debugLabel}`
  }, [config, serverVersion])

  const headerContentWidth = useMemo(() => {
    return Math.max(terminalWidth - 6, 1)
  }, [terminalWidth])

  const titleLine = useMemo(() => {
    return formatSingleLine(title, headerContentWidth)
  }, [headerContentWidth, title])

  const statusLine = useMemo(() => {
    return formatSingleLine(status, headerContentWidth)
  }, [headerContentWidth, status])

  async function openSession(sessionTitle = "OpenTUI Session") {
    const openSessionSeq = openSessionSeqRef.current + 1
    openSessionSeqRef.current = openSessionSeq

    requestAbortRef.current?.abort()
    const abortController = new AbortController()
    requestAbortRef.current = abortController

    socketRef.current?.close()
    socketRef.current = null

    try {
      let configResponse: Response | null = null
      let sessionResponse: Response | null = null

      for (let attempt = 0; attempt < 10; attempt += 1) {
        try {
          ;[configResponse, sessionResponse] = await Promise.all([
            fetch(`${API_BASE}/config`, { signal: abortController.signal }),
            fetch(`${API_BASE}/sessions`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ title: sessionTitle }),
              signal: abortController.signal,
            }),
          ])

          await Promise.all([requireOK(configResponse), requireOK(sessionResponse)])
          break
        } catch (error) {
          if (abortController.signal.aborted) {
            return
          }

          if (attempt === 9) throw error
          setStatus(`Waiting for server… (${attempt + 1}/10)`)
          await sleep(500)
        }
      }

      if (!configResponse || !sessionResponse) {
        throw new Error("Unable to bootstrap session.")
      }

      const loadedConfig = (await configResponse.json()) as ConfigResponse
      const loadedVersion = readServerVersion(configResponse) ?? readServerVersion(sessionResponse)
      const createdSession = (await sessionResponse.json()) as SessionRecord
      const messagesResponse = await requireOK(
        await fetch(`${API_BASE}/sessions/${createdSession.id}/messages`, { signal: abortController.signal }),
      )
      const messagePayload = (await messagesResponse.json()) as { messages: SessionMessage[] }

      if (!mountedRef.current || openSessionSeq !== openSessionSeqRef.current) return
      setConfig(loadedConfig)
      setServerVersion(loadedVersion)
      setSession(createdSession)
      setMessages(messagePayload.messages)
      setStatus(`Connected · session #${createdSession.id}`)

      const socket = new WebSocket(`${WS_BASE}/sessions/${createdSession.id}/stream`)
      socketRef.current = socket

      socket.onopen = () => {
        if (!mountedRef.current) return
        if (openSessionSeq !== openSessionSeqRef.current) return
        setStatus(`Connected · session #${createdSession.id}`)
      }

      socket.onmessage = (event) => {
        if (!mountedRef.current) return
        if (openSessionSeq !== openSessionSeqRef.current) return

        try {
          const payload = JSON.parse(String(event.data)) as StreamEvent

          if (payload.type === "message.created" && payload.message) {
            setMessages((current) => [...current, payload.message!])
            return
          }

          if (payload.type === "tool.called" && payload.toolCall) {
            const suffix = payload.toolCall.argumentsJSON && payload.toolCall.argumentsJSON !== "{}"
              ? ` ${payload.toolCall.argumentsJSON}`
              : ""
            const approvalLabel = payload.toolCall.approved ? "approved" : "denied"
            setMessages((current) => [
              ...current,
              { role: "tool", content: `🛠  ${payload.toolCall!.name}${suffix} [${approvalLabel}]` },
            ])
          }
        } catch (error) {
          setStatus(error instanceof Error ? error.message : "Invalid stream event.")
        }
      }

      socket.onclose = () => {
        if (!mountedRef.current) return
        if (openSessionSeq !== openSessionSeqRef.current) return
        if (socketRef.current === socket) {
          setStatus(`Stream disconnected · session #${createdSession.id}`)
        }
      }
    } catch (error) {
      if (abortController.signal.aborted) return
      if (!mountedRef.current) return
      setStatus(
        formatReconnectHint(error instanceof Error ? error.message : "Unable to connect to apfelclaw-server."),
      )
    } finally {
      if (requestAbortRef.current === abortController) {
        requestAbortRef.current = null
      }
    }
  }

  useEffect(() => {
    mountedRef.current = true

    void openSession()

    return () => {
      mountedRef.current = false
      requestAbortRef.current?.abort()
      requestAbortRef.current = null
      socketRef.current?.close()
      socketRef.current = null
    }
  }, [])

  useKeyboard((key) => {
    if (key.name === "escape") {
      shutdown()
      return
    }

    if (key.name === "return" && input.trim() === "/quit") {
      shutdown()
    }
  })

  async function submitMessage() {
    const content = input.trim()
    if (!content || submitting) return

    setInput("")

    if (content === "/quit") {
      shutdown()
      return
    }

    if (content === "/new") {
      setSubmitting(true)
      setStatus("Creating new session…")
      try {
        await openSession("OpenTUI Session")
      } finally {
        setSubmitting(false)
      }
      return
    }

    if (content === "/help") {
      setMessages((current) => [
        ...current,
        {
          role: "assistant",
          content: [
            "Slash commands:",
            "/new starts a fresh session.",
            "/quit exits the TUI.",
            "/help shows this message.",
            "/version shows the server version.",
            "/config shows config.",
            "/config set assistantName <value>",
            "/config set userName <value>",
            "/config set approvalMode <always|ask-once-per-tool-per-session|trusted-readonly>",
            "/config set debug <true|false>",
            "/remotecontrol shows remote control status.",
            "/remotecontrol setup telegram <botToken>",
            "/remotecontrol status telegram",
            "/remotecontrol disable telegram",
            "/remotecontrol reset telegram",
          ].join("\n"),
        },
      ])
      setStatus("Connected")
      return
    }

    if (content === "/version") {
      const versionText = serverVersion ? `Apfelclaw server version: ${serverVersion}` : "Server version unavailable."
      setMessages((current) => [
        ...current,
        { role: "assistant", content: versionText },
      ])
      setStatus("Connected")
      return
    }

    if (content === "/config") {
      setSubmitting(true)
      setStatus("Loading config…")

      try {
        const response = await requireOK(await fetch(`${API_BASE}/config`))
        const currentConfig = (await response.json()) as ConfigResponse
        setConfig(currentConfig)
        setMessages((current) => [
          ...current,
          { role: "assistant", content: formatConfigSummary(currentConfig) },
        ])
        setStatus("Connected")
      } catch (error) {
        setMessages((current) => [
          ...current,
          { role: "assistant", content: error instanceof Error ? error.message : "Unable to load config." },
        ])
        setStatus("Request failed")
      } finally {
        setSubmitting(false)
      }
      return
    }

    const configUpdate = parseConfigSetCommand(content)
    if (configUpdate) {
      setSubmitting(true)
      setStatus("Updating config…")

      try {
        if (
          configUpdate.field === "debug" &&
          configUpdate.value !== "true" &&
          configUpdate.value !== "false"
        ) {
          throw new Error("debug must be either true or false.")
        }

        const patchValue = configUpdate.field === "debug"
          ? configUpdate.value === "true"
          : configUpdate.value

        const response = await requireOK(
          await fetch(`${API_BASE}/config`, {
            method: "PATCH",
            headers: { "content-type": "application/json" },
            body: JSON.stringify({ [configUpdate.field]: patchValue }),
          }),
        )
        const updatedConfig = (await response.json()) as ConfigResponse
        setConfig(updatedConfig)
        setMessages((current) => [
          ...current,
          {
            role: "assistant",
            content: `Updated config.\n${formatConfigSummary(updatedConfig)}`,
          },
        ])
        setStatus("Connected")
      } catch (error) {
        setMessages((current) => [
          ...current,
          { role: "assistant", content: error instanceof Error ? error.message : "Unable to update config." },
        ])
        setStatus("Request failed")
      } finally {
        setSubmitting(false)
      }
      return
    }

    const remoteControlCommand = parseRemoteControlCommand(content)
    if (remoteControlCommand) {
      setSubmitting(true)
      setStatus("Updating remote control…")

      try {
        if (remoteControlCommand.action === "show") {
          const response = await requireOK(await fetch(`${API_BASE}/remotecontrol`))
          const statusPayload = (await response.json()) as RemoteControlStatus
          setMessages((current) => [
            ...current,
            { role: "assistant", content: formatRemoteControlSummary(statusPayload) },
          ])
          setStatus("Connected")
          return
        }

        if (remoteControlCommand.action === "status") {
          const response = await requireOK(await fetch(`${API_BASE}/remotecontrol/providers/telegram`))
          const statusPayload = (await response.json()) as TelegramRemoteControlStatus
          setMessages((current) => [
            ...current,
            { role: "assistant", content: formatTelegramRemoteStatus(statusPayload) },
          ])
          setStatus("Connected")
          return
        }

        if (remoteControlCommand.action === "setup") {
          const response = await requireOK(
            await fetch(`${API_BASE}/remotecontrol/providers/telegram/setup`, {
              method: "POST",
              headers: { "content-type": "application/json" },
              body: JSON.stringify({ botToken: remoteControlCommand.botToken }),
            }),
          )
          const statusPayload = (await response.json()) as TelegramRemoteControlStatus
          setMessages((current) => [
            ...current,
            { role: "assistant", content: formatTelegramRemoteStatus(statusPayload) },
          ])
          setStatus("Connected")
          return
        }

        if (remoteControlCommand.action === "disable") {
          const response = await requireOK(
            await fetch(`${API_BASE}/remotecontrol/providers/telegram/disable`, { method: "POST" }),
          )
          const statusPayload = (await response.json()) as TelegramRemoteControlStatus
          setMessages((current) => [
            ...current,
            { role: "assistant", content: formatTelegramRemoteStatus(statusPayload) },
          ])
          setStatus("Connected")
          return
        }

        const response = await requireOK(
          await fetch(`${API_BASE}/remotecontrol/providers/telegram/reset`, { method: "POST" }),
        )
        const statusPayload = (await response.json()) as TelegramRemoteControlStatus
        setMessages((current) => [
          ...current,
          { role: "assistant", content: formatTelegramRemoteStatus(statusPayload) },
        ])
        setStatus("Connected")
      } catch (error) {
        setMessages((current) => [
          ...current,
          { role: "assistant", content: error instanceof Error ? error.message : "Unable to update remote control." },
        ])
        setStatus("Request failed")
      } finally {
        setSubmitting(false)
      }
      return
    }

    if (!session) return

    setSubmitting(true)
    setStatus("Waiting for response…")

    try {
      const response = await fetch(`${API_BASE}/sessions/${session.id}/messages`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ content, autoApproveTools: true }),
      })
      await requireOK(response)
      setStatus("Connected")
    } catch (error) {
      setMessages((current) => [
        ...current,
        { role: "assistant", content: error instanceof Error ? error.message : "Request failed." },
      ])
      setStatus("Request failed")
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <box
      style={{
        flexDirection: "column",
        width: terminalWidth,
        height: terminalHeight,
        padding: 1,
        gap: 1,
        backgroundColor: "#0a0d12",
      }}
    >
      <box style={{ border: true, borderColor: "#ffffff", flexDirection: "column", height: 4 }}>
        <box style={{ height: 1, marginLeft: 1, marginRight: 1 }}>
          <text content={titleLine} fg="#fff2a8" />
        </box>
        <box style={{ height: 1, marginLeft: 1, marginRight: 1 }}>
          <text content={statusLine} fg="#c6d3e3" />
        </box>
      </box>

      <box style={{ flexGrow: 1, minHeight: 3 }}>
        <scrollbox
          stickyScroll
          stickyStart="bottom"
          style={{
            width: "100%",
            height: "100%",
            border: true,
            borderColor: "#ffffff",
            padding: 1,
          }}
        >
          {
            // Render transcript one terminal line at a time so multiline messages
            // do not become oversized scrollbox children with clipped blank space.
            messages.flatMap((message, messageIndex) =>
              splitMessageLines(message.content).map((line, lineIndex, lines) => (
                <box
                  key={`${message.role}-${messageIndex}-${lineIndex}`}
                  style={{ flexDirection: "row", marginBottom: lineIndex === lines.length - 1 ? 1 : 0 }}
                >
                  <box style={{ width: TRANSCRIPT_LABEL_WIDTH, flexShrink: 0 }}>
                    {lineIndex === 0 ? (
                      <text fg={roleColor(message.role)}>{labelForRole(message.role, config)}</text>
                    ) : null}
                  </box>
                  <box style={{ flexGrow: 1, flexShrink: 1, minWidth: 0 }}>
                    <text fg="#f4f7fb">{line.length > 0 ? line : " "}</text>
                  </box>
                </box>
              )),
            )
          }
        </scrollbox>
      </box>

      <box title="Chat /new /quit /help" style={{ border: true, borderColor: "#ffffff", padding: 1, height: 3 }}>
        <input
          value={input}
          focused
          placeholder="Send a message to Apfelclaw…"
          onInput={setInput}
          onSubmit={submitMessage}
        />
      </box>
    </box>
  )
}

const renderer = await createCliRenderer({ exitOnCtrlC: true })
const root = createRoot(renderer)

let exiting = false
const shutdown = () => {
  if (exiting) return
  exiting = true
  root.unmount()
  renderer.destroy()
}

root.render(<App shutdown={shutdown} />)
