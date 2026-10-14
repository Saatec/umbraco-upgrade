// Synthetic fixture: a minimal web component dashboard.
export default class SampleWelcomeDashboard extends HTMLElement {
    connectedCallback() {
        this.textContent = 'Welcome';
    }
}
customElements.define('sample-welcome-dashboard', SampleWelcomeDashboard);
