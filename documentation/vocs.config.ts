import { defineConfig } from 'vocs'

export default defineConfig({
  title: 'Boo',
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
      text: 'Updates',
      link: '/updates',
    },
    {
      text: 'Keyboard Shortcuts',
      link: '/keyboard-shortcuts',
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
