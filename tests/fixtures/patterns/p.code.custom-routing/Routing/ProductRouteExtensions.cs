using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Routing;

namespace SampleSite.Web.Routing;

// Synthetic fixture: a custom route next to the CMS pipeline.
public static class ProductRouteExtensions
{
    public static void MapProductRoutes(this IEndpointRouteBuilder endpoints)
    {
        endpoints.MapControllerRoute(
            "Products",
            "/products/{id?}",
            new { Controller = "Products", Action = "Index" });
    }
}
