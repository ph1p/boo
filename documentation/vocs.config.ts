import { defineConfig } from 'vocs/config'

export default defineConfig({
  title: 'Boo',
  titleTemplate: '%s – Boo',
  description:
    'Boo is a native macOS terminal for coding agents, built on Ghostty. Workspaces, split panes, agent tracking, review mode and a plugin sidebar.',
  srcDir: 'docs',
  renderStrategy: 'full-static',
  basePath: '/boo',
  baseUrl: 'https://ph1p.github.io',
  logoUrl: '/logo.png',
  iconUrl: '/logo.png',
  ogImageUrl: 'https://ph1p.github.io/boo/social-preview.png',
  editLink: {
    link: 'https://github.com/ph1p/boo/edit/main/documentation/docs/pages/:path',
    text: 'Edit this page on GitHub',
  },
  socials: [{ icon: 'github', link: 'https://github.com/ph1p/boo' }],
  topNav: [
    { text: 'Docs', link: '/getting-started' },
    { text: 'Agents', link: '/agents' },
    { text: 'Plugins', link: '/plugin-development' },
    { text: 'Download', link: 'https://github.com/ph1p/boo/releases/latest' },
  ],
  sidebar: [
    {
      text: 'Get Started',
      items: [
        { text: 'Installation', link: '/installation' },
        { text: 'Getting Started', link: '/getting-started' },
        { text: 'Updates', link: '/updates' },
      ],
    },
    {
      text: 'Using Boo',
      items: [
        { text: 'Features', link: '/features' },
        { text: 'Windows & Splits', link: '/windows-and-splits' },
        { text: 'Multi-Content Tabs', link: '/multi-content-tabs' },
        { text: 'Keyboard Shortcuts', link: '/keyboard-shortcuts' },
        { text: 'Rules & Profiles', link: '/rules-and-profiles' },
        { text: 'History & Sync', link: '/history-and-sync' },
        { text: 'Security', link: '/security' },
      ],
    },
    {
      text: 'Agents & Automation',
      items: [
        { text: 'Agents', link: '/agents' },
        { text: 'IPC Socket & MCP', link: '/ipc-socket' },
      ],
    },
    {
      text: 'Remote',
      items: [
        { text: 'Remote Sessions', link: '/remote-sessions' },
        { text: 'Remote Control', link: '/remote-control' },
      ],
    },
    {
      text: 'Extending Boo',
      items: [
        { text: 'Plugin System', link: '/plugins' },
        { text: 'Plugin Development', link: '/plugin-development' },
        { text: 'Theming', link: '/theming' },
      ],
    },
    {
      text: 'Internals',
      items: [
        { text: 'Architecture', link: '/architecture' },
        { text: 'Ghostty Integration', link: '/ghostty-integration' },
        { text: 'Contributing', link: '/contributing' },
      ],
    },
  ],
})
