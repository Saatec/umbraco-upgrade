using System.Configuration;

namespace SampleSite.Web
{
    // Synthetic fixture: reads project settings statically.
    public static class SiteOptions
    {
        public static string SupportEmail => ConfigurationManager.AppSettings["SampleSite.SupportEmail"];
    }
}
