using System.Linq;
using System.Web;
using Umbraco.Core;
using Umbraco.Web;

namespace SampleSite.Web
{
    // Synthetic fixture: static access to services and the current request.
    public static class LatestNews
    {
        public static string FirstTitle()
        {
            var services = ApplicationContext.Current.Services;
            var root = UmbracoContext.Current.ContentCache.GetAtRoot().FirstOrDefault();
            var host = HttpContext.Current.Request.Url.Host;
            return root == null ? host : root.Name + " on " + host + " (" + services.ContentService.Count() + ")";
        }
    }
}
