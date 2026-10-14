// Synthetic fixture: front-end script calling the auto-routed API.
function loadCategories() {
    return fetch('/umbraco/api/catalogapi/getcategories')
        .then(function (response) { return response.json(); });
}
