import { useEffect } from 'react'
import { useReveal } from './lib/fx.js'
import Nav from './ui/Nav.jsx'
import Rail from './ui/Rail.jsx'
import Hero from './sections/Hero.jsx'
import Pipeline from './sections/Pipeline.jsx'
import Box from './sections/Box.jsx'
import Look from './sections/Look.jsx'
import Editor from './sections/Editor.jsx'
import Agent from './sections/Agent.jsx'
import Install from './sections/Install.jsx'
import Footer from './sections/Footer.jsx'

const MARKS = [
  { id: 'top', tc: '00:00', label: 'Overview' },
  { id: 'how', tc: '00:12', label: 'How it works' },
  { id: 'box', tc: '00:26', label: 'Capture' },
  { id: 'look', tc: '00:40', label: 'The look' },
  { id: 'editor', tc: '01:04', label: 'Editor' },
  { id: 'agents', tc: '01:30', label: 'Agents' },
  { id: 'get', tc: '01:56', label: 'Get it' },
]

export default function App() {
  useReveal()

  /* The browser tries to honour a #hash before React has mounted the sections,
     so a deep link would otherwise land at the top. Jump once, after layout. */
  useEffect(() => {
    const id = decodeURIComponent(window.location.hash.slice(1))
    if (!id) return
    requestAnimationFrame(() => document.getElementById(id)?.scrollIntoView())
  }, [])

  return (
    <>
      <a
        href="#how"
        className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-[60] focus:rounded-full focus:bg-panel focus:px-4 focus:py-2"
      >
        Skip to content
      </a>
      <Nav />
      <Rail marks={MARKS} />
      <main id="top">
        <Hero />
        <Pipeline />
        <Box />
        <Look />
        <Editor />
        <Agent />
        <Install />
      </main>
      <Footer />
    </>
  )
}
