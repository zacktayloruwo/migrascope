import { mount } from 'svelte'
import App from './App.svelte'
import './styles/tokens.css'

mount(App, { target: document.getElementById('app')! })
