import React from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import "@fontsource/ibm-plex-mono";
import "@fontsource/ibm-plex-sans";
import "@fontsource/ibm-plex-serif";
import "@fontsource/inter";
import "@fontsource/playpen-sans";
import "@fontsource/poppins";
import "@fontsource/source-sans-3";
import "@fontsource/source-serif-4";
import "@fontsource/tilt-neon";
import "@fontsource/ubuntu-mono";
import "./styles.css";

const rootElement = document.getElementById("root");

if (rootElement !== null) {
  createRoot(rootElement).render(
    <React.StrictMode>
      <App />
    </React.StrictMode>,
  );
}
