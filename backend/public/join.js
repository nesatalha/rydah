const token = new URLSearchParams(location.hash.slice(1)).get('token');
history.replaceState(null, '', location.pathname);
const invitation = token ? `${location.origin}/join.html#token=${encodeURIComponent(token)}` : null;
const copy = document.getElementById('copy-invitation');
const message = document.getElementById('join-message');
copy.disabled = !invitation;
if (!invitation) {
    message.textContent = 'Open the full invitation link supplied by your group owner.';
}
copy.addEventListener('click', async () => {
    if (!invitation) {
        return;
    }
    try {
        await navigator.clipboard.writeText(invitation);
        message.textContent = 'Invitation copied. Paste it into Join group in the Rydah Android app.';
    }
    catch {
        message.textContent = 'Copy is unavailable here. Copy the original invitation from the message your owner sent.';
    }
});
