using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.ViewEngines;
using Microsoft.Extensions.Logging;
using Umbraco.Cms.Core.Web;
using Umbraco.Cms.Web.Common.Controllers;

namespace SampleSite.Web.Controllers;

// Synthetic fixture: route hijacking for the "articlePage" content type.
public class ArticlePageController : RenderController
{
    public ArticlePageController(
        ILogger<ArticlePageController> logger,
        ICompositeViewEngine compositeViewEngine,
        IUmbracoContextAccessor umbracoContextAccessor)
        : base(logger, compositeViewEngine, umbracoContextAccessor)
    {
    }

    public override IActionResult Index()
    {
        return CurrentTemplate(CurrentPage);
    }
}
