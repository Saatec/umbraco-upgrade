using System.Linq;
using Umbraco.Web;

namespace SampleSite.Web
{
    // Synthetic fixture: finds the settings node by XPath.
    public class SiteSettings
    {
        private readonly UmbracoHelper _umbraco;

        public SiteSettings(UmbracoHelper umbraco)
        {
            _umbraco = umbraco;
        }

        public string FooterText()
        {
            var settings = _umbraco.ContentAtXPath("//siteSettings").FirstOrDefault();
            return settings == null ? string.Empty : settings.Name;
        }
    }
}
