import { defineConfig } from 'vocs/config'

export default defineConfig({
  title: 'Boo',
  srcDir: 'docs',
  renderStrategy: 'full-static',
  basePath: '/boo',
  logoUrl: '/logo.png',
  sidebar: [
    {
      text: 'Installation',
      link: '/installation',
    },
    {
      text: 'Getting Started',
      link: '/getting-started',
    },
    {
      text: 'Features',
      link: '/features',
    },
    {
      text: 'Windows & Splits',
      link: '/windows-and-splits',
    },
    {
      text: 'Agents',
      link: '/agents',
    },
    {
      text: 'Updates',
      link: '/updates',
    },
    {
      text: 'Keyboard Shortcuts',
      link: '/keyboard-shortcuts',
    },
    {
      text: 'Remote Control',
      link: '/remote-control',
    },
    {
      text: 'Architecture',
      items: [
        {
          text: 'Overview',
          link: '/architecture',
        },
        {
          text: 'Ghostty Integration',
          link: '/ghostty-integration',
        },
        {
          text: 'Multi-Content Tabs',
          link: '/multi-content-tabs',
        },
        {
          text: 'Remote Sessions',
          link: '/remote-sessions',
        },
        {
          text: 'IPC Socket',
          link: '/ipc-socket',
        },
        {
          text: 'Plugin System',
          link: '/plugins',
        },
        {
          text: 'Plugin Development',
          link: '/plugin-development',
        },
        {
          text: 'Theming',
          link: '/theming',
        },
      ],
    },
    {
      text: 'Contributing',
      link: '/contributing',
    },
  ],
})
