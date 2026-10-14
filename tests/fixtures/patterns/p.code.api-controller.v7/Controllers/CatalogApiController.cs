using System.Collections.Generic;
using Umbraco.Web.WebApi;

namespace SampleSite.Web.Controllers
{
    // Synthetic fixture: auto-routed at /umbraco/api/catalogapi/getcategories
    public class CatalogApiController : UmbracoApiController
    {
        public IEnumerable<string> GetCategories()
        {
            return new[] { "Tables", "Chairs" };
        }
    }
}
