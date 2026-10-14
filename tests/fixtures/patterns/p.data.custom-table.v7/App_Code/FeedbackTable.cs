using System;
using Umbraco.Core;
using Umbraco.Core.Persistence;
using Umbraco.Core.Persistence.DatabaseAnnotations;

namespace SampleSite.Data
{
    // Synthetic fixture: custom table definition.
    [TableName("sampleFeedback")]
    [PrimaryKey("Id", autoIncrement = true)]
    [ExplicitColumns]
    public class FeedbackRecord
    {
        [Column("Id")]
        [PrimaryKeyColumn(AutoIncrement = true)]
        public int Id { get; set; }

        [Column("Comment")]
        [Length(500)]
        public string Comment { get; set; }

        [Column("CreatedUtc")]
        public DateTime CreatedUtc { get; set; }
    }

    // Synthetic fixture: creates the table at application start.
    public class FeedbackTableEventHandler : ApplicationEventHandler
    {
        protected override void ApplicationStarted(UmbracoApplicationBase umbracoApplication, ApplicationContext applicationContext)
        {
            var ctx = applicationContext.DatabaseContext;
            var schema = new DatabaseSchemaHelper(ctx.Database, applicationContext.ProfilingLogger.Logger, ctx.SqlSyntax);
            if (!schema.TableExist("sampleFeedback"))
            {
                schema.CreateTable<FeedbackRecord>(false);
            }
        }
    }
}
