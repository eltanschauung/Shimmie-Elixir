// Keep user names in data/text contexts, never executable JavaScript URLs.
(function () {
  document.addEventListener("click", function (event) {
    if (event.defaultPrevented || event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest && event.target.closest("a[data-comment-reply]");
    if (!link) return;
    const { imageId, commentId, username } = link.dataset;
    if (!/^[1-9]\d*$/.test(imageId) || !/^[1-9]\d*$/.test(commentId)) return;
    const box = document.getElementById("comment_on_" + imageId);
    // Without an inline form, follow the ordinary link to the post's form.
    if (!box) return;
    event.preventDefault();
    box.focus();
    box.value += `[url=site://post/view/${imageId}#c${commentId}]@${username}[/url]: `;
    const comment = document.getElementById("c" + commentId);
    if (comment && typeof window.shm_blink === "function") window.shm_blink(comment);
  });
})();
