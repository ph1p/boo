'use client'

import { useEffect } from 'react'

// The site root is the static landing page (copied over dist/public/index.html
// after `vocs build`). Client-side navigation to "/" still renders this MDX
// page, so force a full load. Dev has no copied file, so go to the source.
export function LandingRedirect() {
  useEffect(() => {
    window.location.replace(import.meta.env.DEV ? '/boo/landing/index.html' : '/boo/')
  }, [])
  return null
}
