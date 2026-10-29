using log4net;

namespace SampleSite.Web
{
    // Synthetic fixture: logs through a legacy library.
    public static class ImportLog
    {
        private static readonly ILog Log = LogManager.GetLogger(typeof(ImportLog));

        public static void Started() => Log.Info("Import started");
    }
}
