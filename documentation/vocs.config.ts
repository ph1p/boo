import { defineConfig } from 'vocs'

export default defineConfig({
  title: 'Boo',
  basePath: '/boo',
  logoUrl: '/boo/logo.png',
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
          text: 'Remote Sessions',
          link: '/remote-sessions',
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
