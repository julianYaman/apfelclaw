import React, { useEffect, useMemo, useState } from 'react'
import { Box, Text, render, useApp, useInput } from 'ink'
import TextInput from 'ink-text-input'

const e = React.createElement

export async function runInteractiveOnboarding(options) {
  return await new Promise((resolve, reject) => {
    const app = render(
      e(OnboardingApp, {
        options,
        onResolve(value) {
          resolve(value)
          app.unmount()
        },
        onReject(error) {
          reject(error)
          app.unmount()
        },
      })
    )
  })
}

function OnboardingApp({ options, onResolve, onReject }) {
  const { exit } = useApp()
  const [phase, setPhase] = useState('welcome')
  const [assistantName, setAssistantName] = useState(options.currentConfig.assistantName)
  const [userName, setUserName] = useState(options.currentConfig.userName)
  const [approvalMode, setApprovalMode] = useState(options.currentConfig.approvalMode)
  const [autostartEnabled, setAutostartEnabled] = useState(options.currentConfig.apfelAutostartEnabled)
  const [telegramToken, setTelegramToken] = useState('')
  const [telegramStatus, setTelegramStatus] = useState(null)
  const [telegramNote, setTelegramNote] = useState('')

  function finish(value) {
    onResolve(value)
    exit()
  }

  function fail(error) {
    onReject(error)
    exit()
  }

  if (phase === 'welcome') {
    return e(ContinueScreen, {
      step: 0,
      total: 6,
      title: 'Welcome to apfelclaw',
      description:
        'A local-first macOS AI agent that uses apfel for on-device model execution. This guide will save your defaults, start the backend, and optionally connect Telegram.',
      actionLabel: 'Press Enter to begin',
      accentColor: 'magenta',
      onContinue: () => setPhase('assistant'),
    })
  }

  if (phase === 'assistant') {
    return e(TextEntryScreen, {
      step: 1,
      total: 6,
      title: 'Assistant Identity',
      description: 'Pick the name your local assistant should use.',
      label: 'Assistant name',
      value: assistantName,
      onChange: setAssistantName,
      onSubmit: () => setPhase('user'),
    })
  }

  if (phase === 'user') {
    return e(TextEntryScreen, {
      step: 2,
      total: 6,
      title: 'Your Profile',
      description: 'Tell apfelclaw what to call you.',
      label: 'Your name',
      value: userName,
      onChange: setUserName,
      onSubmit: () => setPhase('approval'),
    })
  }

  if (phase === 'approval') {
    return e(SelectScreen, {
      key: 'approval',
      step: 3,
      total: 6,
      title: 'Approval Mode',
      description: 'Choose how cautious apfelclaw should be before it runs tools.',
      items: [
        { label: 'Always ask', value: 'always', description: 'Prompt before every tool call.' },
        {
          label: 'Ask once per tool per session',
          value: 'ask-once-per-tool-per-session',
          description: 'Approve each tool once for the current conversation.',
        },
        {
          label: 'Trusted read-only',
          value: 'trusted-readonly',
          description: 'Auto-approve read-only tools and still confirm risky actions.',
        },
      ],
      initialValue: approvalMode,
      onSubmit(value) {
        setApprovalMode(value)
        setPhase('autostart')
      },
    })
  }

  if (phase === 'autostart') {
    return e(SelectScreen, {
      key: 'autostart',
      step: 4,
      total: 6,
      title: 'apfel Startup',
      description: 'Decide whether apfelclaw may start apfel automatically when it needs the model backend.',
      items: [
        { label: 'Enable', value: true, description: 'Recommended for a smoother first-run experience.' },
        { label: 'Disable', value: false, description: 'You will manage apfel manually.' },
      ],
      initialValue: autostartEnabled,
      onSubmit(value) {
        setAutostartEnabled(value)
        setPhase('starting-backend')
      },
    })
  }

  if (phase === 'starting-backend') {
    return e(AsyncStep, {
      step: 5,
      total: 6,
      title: 'Starting the Backend',
      description: 'Saving your defaults and bringing up the local backend in the background.',
      task: async () => {
        await options.persistConfig({
          ...options.currentConfig,
          assistantName: assistantName.trim(),
          userName: userName.trim(),
          approvalMode,
          apfelAutostartEnabled: autostartEnabled,
        })
        await options.startBackend()
      },
      onSuccess: () => setPhase('remote-control'),
      onError: fail,
    })
  }

  if (phase === 'remote-control') {
    return e(SelectScreen, {
      key: 'remote-control',
      step: 6,
      total: 6,
      title: 'Remote Control',
      description: 'You can optionally connect Telegram now and skip setting it up later in the chat app.',
      items: [
        { label: 'Skip for now', value: 'skip', description: 'Finish setup without a remote provider.' },
        {
          label: 'Setup Telegram',
          value: 'telegram',
          description: 'Verify a Telegram bot token and optionally finish linking now.',
        },
      ],
      initialValue: 'skip',
      onSubmit(value) {
        if (value === 'skip') {
          finish({
            assistantName: assistantName.trim(),
            userName: userName.trim(),
            approvalMode,
            apfelAutostartEnabled: autostartEnabled,
            telegramConfigured: false,
            telegramLinked: false,
          })
          return
        }
        setPhase('telegram-token')
      },
    })
  }

  if (phase === 'telegram-token') {
    return e(TextEntryScreen, {
      step: 6,
      total: 6,
      title: 'Telegram Setup',
      description: 'Paste your BotFather token. It will be verified before it is saved.',
      label: 'Telegram bot token',
      value: telegramToken,
      secret: true,
      onChange: setTelegramToken,
      onSubmit: () => setPhase('verifying-telegram'),
    })
  }

  if (phase === 'verifying-telegram') {
    return e(AsyncStep, {
      step: 6,
      total: 6,
      title: 'Verifying Telegram',
      description: 'Checking the bot token with Telegram and enabling linking mode.',
      task: async () => options.setupTelegram(telegramToken.trim()),
      onSuccess(status) {
        setTelegramStatus(status)
        setTelegramNote('')
        setPhase('telegram-link-choice')
      },
      onError: fail,
    })
  }

  if (phase === 'telegram-link-choice') {
    return e(SelectScreen, {
      key: 'telegram-link-choice',
      step: 6,
      total: 6,
      title: 'Telegram Linking',
      description: `Send a private message to @${telegramStatus?.botUsername ?? 'your bot'} now. apfelclaw will finish linking as soon as it sees the first private message.${
        telegramNote ? `\n\n${telegramNote}` : ''
      }`,
      items: [
        { label: 'Wait for Telegram link now', value: 'wait', description: 'Poll the backend and finish linking in this setup flow.' },
        { label: 'Continue for now', value: 'continue', description: 'Finish setup and let the link complete later.' },
      ],
      initialValue: 'continue',
      onSubmit(value) {
        if (value === 'continue') {
          finish({
            assistantName: assistantName.trim(),
            userName: userName.trim(),
            approvalMode,
            apfelAutostartEnabled: autostartEnabled,
            telegramConfigured: true,
            telegramLinked: false,
          })
          return
        }
        setPhase('waiting-telegram')
      },
    })
  }

  if (phase === 'waiting-telegram') {
    return e(AsyncStep, {
      step: 6,
      total: 6,
      title: 'Waiting for Telegram',
      description: `Watching for the first private message to @${telegramStatus?.botUsername ?? 'your bot'}.`,
      task: async () => options.waitForTelegramLink(),
      onSuccess(linked) {
        if (linked) {
          finish({
            assistantName: assistantName.trim(),
            userName: userName.trim(),
            approvalMode,
            apfelAutostartEnabled: autostartEnabled,
            telegramConfigured: true,
            telegramLinked: true,
          })
          return
        }
        setTelegramNote('Telegram is configured, but the private chat link has not completed yet.')
        setPhase('telegram-link-choice')
      },
      onError: fail,
    })
  }

  return null
}

function Screen({ step, total, title, description, children, footer }) {
  return e(
    Box,
    { flexDirection: 'column', paddingTop: 1, paddingBottom: 1 },
    e(Text, { color: 'cyanBright' }, step > 0 ? `Step ${step} of ${total}` : 'Welcome'),
    e(Text, { bold: true }, title),
    e(Box, { marginTop: 1, marginBottom: 1 }, e(Text, null, description)),
    e(Box, { flexDirection: 'column' }, children),
    footer ? e(Box, { marginTop: 1 }, e(Text, { color: 'gray' }, footer)) : null
  )
}

function ContinueScreen({ step, total, title, description, actionLabel, accentColor, onContinue }) {
  useInput((input, key) => {
    if (key.return) {
      onContinue()
    }
  })

  return e(
    Box,
    { flexDirection: 'column', paddingTop: 1 },
    e(Text, { color: accentColor, bold: true }, title),
    e(Box, { marginTop: 1, marginBottom: 1 }, e(Text, null, description)),
    e(Text, { color: 'gray' }, actionLabel)
  )
}

function TextEntryScreen({ step, total, title, description, label, value, onChange, onSubmit, secret = false }) {
  return e(
    Screen,
    {
      step,
      total,
      title,
      description,
      footer: 'Type your answer and press Enter to continue.',
    },
    e(Text, { bold: true }, label),
    e(Box, { marginTop: 1 }, e(TextInput, {
      value,
      mask: secret ? '*' : undefined,
      onChange,
      onSubmit(nextValue) {
        if (nextValue.trim().length === 0) {
          return
        }
        onSubmit(nextValue.trim())
      },
    }))
  )
}

function SelectScreen({ step, total, title, description, items, initialValue, onSubmit }) {
  const [selectedIndex, setSelectedIndex] = useState(() => {
    const found = items.findIndex((item) => item.value === initialValue)
    return found >= 0 ? found : 0
  })

  useEffect(() => {
    const found = items.findIndex((item) => item.value === initialValue)
    setSelectedIndex(found >= 0 ? found : 0)
  }, [items, initialValue])

  useInput((input, key) => {
    if (key.upArrow || input === 'k') {
      setSelectedIndex((current) => (current === 0 ? items.length - 1 : current - 1))
      return
    }

    if (key.downArrow || input === 'j') {
      setSelectedIndex((current) => (current === items.length - 1 ? 0 : current + 1))
      return
    }

    if (key.return && items[selectedIndex]) {
      onSubmit(items[selectedIndex].value)
    }
  })

  const selected = useMemo(() => items[selectedIndex] ?? items[0] ?? null, [items, selectedIndex])

  return e(
    Screen,
    {
      step,
      total,
      title,
      description,
      footer: 'Use ↑ ↓ and Enter to choose an option.',
    },
    ...items.flatMap((item, index) => [
      e(
        Box,
        { key: `${String(item.value)}-row`, flexDirection: 'column', marginBottom: 1 },
        e(Text, { color: index === selectedIndex ? 'cyanBright' : 'white' }, `${index === selectedIndex ? '›' : ' '} ${item.label}`),
        e(Text, { color: 'gray' }, item.description)
      ),
    ]),
    selected ? e(Box, { marginTop: 1 }, e(Text, { color: 'yellow' }, `Selected: ${selected.label}`)) : null
  )
}

function AsyncStep({ step, total, title, description, task, onSuccess, onError }) {
  useEffect(() => {
    let cancelled = false

    ;(async () => {
      try {
        const result = await task()
        if (!cancelled) {
          onSuccess(result)
        }
      } catch (error) {
        if (!cancelled) {
          onError(error)
        }
      }
    })()

    return () => {
      cancelled = true
    }
  }, [onError, onSuccess, task])

  return e(
    Screen,
    {
      step,
      total,
      title,
      description,
      footer: 'Working…',
    },
    e(Text, { color: 'cyan' }, 'Please wait.')
  )
}
