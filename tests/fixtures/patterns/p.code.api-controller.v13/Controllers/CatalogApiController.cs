using Microsoft.AspNetCore.Mvc;
using Umbraco.Cms.Web.Common.Controllers;

namespace SampleSite.Web.Controllers;

// Synthetic fixture: API controller for front-end scripts.
[Route("api/catalog/[action]")]
public class CatalogApiController : UmbracoApiController
{
    public IEnumerable<string> GetCategories()
    {
        return new[] { "Tables", "Chairs" };
    }
}
