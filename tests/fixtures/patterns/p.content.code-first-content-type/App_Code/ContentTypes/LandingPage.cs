namespace SampleSite.ContentTypes
{
    [UmbracoContentType("Landing Page", "landingPage", null, true)]
    public class LandingPage
    {
        [UmbracoProperty("Heading", "heading", "Umbraco.Textbox", "Textstring")]
        public string Heading { get; set; }
    }
}
