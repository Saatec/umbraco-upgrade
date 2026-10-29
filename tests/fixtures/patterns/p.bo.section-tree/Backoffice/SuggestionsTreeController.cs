using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Umbraco.Cms.Core.Events;
using Umbraco.Cms.Core.Models.Trees;
using Umbraco.Cms.Core.Services;
using Umbraco.Cms.Core.Trees;
using Umbraco.Cms.Web.BackOffice.Trees;
using Umbraco.Cms.Web.Common.Attributes;

namespace SampleSite.Web.Backoffice;

// Synthetic fixture: a tree that lists visitor suggestions.
[Tree("suggestions", "suggestionsTree", TreeTitle = "Suggestions")]
public class SuggestionsTreeController : TreeController
{
    public SuggestionsTreeController(ILocalizedTextService localizedTextService, UmbracoApiControllerTypeCollection umbracoApiControllerTypeCollection, IEventAggregator eventAggregator)
        : base(localizedTextService, umbracoApiControllerTypeCollection, eventAggregator)
    {
    }

    protected override ActionResult<TreeNodeCollection> GetTreeNodes(string id, FormCollection queryStrings) => new TreeNodeCollection();

    protected override ActionResult<MenuItemCollection> GetMenuForNode(string id, FormCollection queryStrings) => new MenuItemCollection();
}
