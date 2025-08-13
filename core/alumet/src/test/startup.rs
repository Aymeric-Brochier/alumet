use crate::{
    agent::{self, builder::TestExpectations},
    measurement::{MeasurementType, WrappedMeasurementType},
    pipeline::naming::{OutputName, SourceName, TransformName},
    test::runtime::{TESTER_PLUGIN_NAME, TESTER_SOURCE_NAME},
    units::PrefixedUnit,
};

/// Structure representing startup expectations.
///
/// `StartupExpectations` allows to define assertions that must be verified when the agent starts.
/// More precisely, the checks are applied after every plugin has started and before the
/// measurement pipeline starts.
///
/// `StartupExpectations` is declarative: you don't perform any `assert!` yourself,
/// you declare the state that you expect and the assertions are called at the right place
/// automatically.
///
/// # Example
///
/// ```no_run
/// use std::time::Duration;
///
/// use alumet::agent;
/// use alumet::test::StartupExpectations;
/// use alumet::units::Unit;
///
/// const TIMEOUT: Duration = Duration::from_secs(2);
///
/// // define the checks that you want to apply
/// let startup = StartupExpectations::new()
///     .expect_metric::<u64>("coffee_counter", Unit::Unity)
///     .expect_source("plugin", "coffee_source")
///     .expect_output("plugin", "coffee_output")
///     .expect_transform("plugin", "coffee_transform");
///
/// // start an Alumet agent
/// let plugins = todo!();
/// let agent = agent::Builder::new(plugins)
///     .with_expectations(startup) // load the checks
///     .build_and_start()
///     .unwrap();
///
/// // stop the agent
/// agent.pipeline.control_handle().shutdown();
/// // wait for the agent to stop
/// agent.wait_for_shutdown(TIMEOUT).unwrap();
/// ```
#[derive(Default)]
pub struct StartupExpectations {
    /// List of expected metrics.
    metrics: Vec<Metric>,
    /// List of expected plugins.
    plugins: Vec<String>,
    /// List of expected sources.
    sources: Vec<SourceName>,
    /// List of expected transforms.
    transforms: Vec<TransformName>,
    /// List of expected outputs.
    outputs: Vec<OutputName>,
}

pub struct Metric {
    pub name: String,
    pub value_type: WrappedMeasurementType,
    pub unit: PrefixedUnit,
}

impl TestExpectations for StartupExpectations {
    /// Sets up closures to test if all previous metrics, element source and element transform are correctly
    /// added to the agent.
    fn setup(self, mut builder: agent::Builder) -> agent::Builder {
        builder = builder.after_plugins_start(|p| {
            // Check that the metrics are the ones we expect.
            let state = p.inspect();
            for expected_metric in self.metrics {
                let expected_name = &expected_metric.name;
                let actual_metric = state.metrics().by_name(expected_name);
                match actual_metric {
                    Some((_, metric_def)) => {
                        assert_eq!(
                            metric_def.name, expected_metric.name,
                            "MetricRegistry is inconsistent: lookup by name {} returned {:?}",
                            expected_name, metric_def
                        );
                        assert_eq!(
                            metric_def.unit, expected_metric.unit,
                            "StartupExpectations not fulfilled: metric {} should have unit {}, not {}",
                            expected_name, expected_metric.unit, metric_def.unit
                        );
                        assert_eq!(
                            metric_def.value_type, expected_metric.value_type,
                            "StartupExpectations not fulfilled: metric {} should have type {}, not {}",
                            expected_name, expected_metric.value_type, metric_def.value_type
                        );
                    }
                    None => {
                        panic!("StartupExpectations not fulfilled: missing metric {}", expected_name);
                    }
                }
            }
        });

        builder = builder.after_plugins_init(|plugins| {
            // Check the list of initialized plugins.
            for plugin in self.plugins {
                // The complexity here could be optimized, but a test typically won't have many plugins so it's ok.
                assert!(
                    plugins.iter().find(|p| p.name() == plugin).is_some(),
                    "StartupExpectations not fulfilled: plugin {} not found",
                    plugin
                );
            }
        });

        builder = builder.before_operation_begin(|pipeline| {
            // Check that the sources, transforms and outputs that we want exist.
            let mut actual_sources = pipeline.inspect().sources();

            // ignore the "tester" source added by RuntimeExpectations
            actual_sources.retain(|s| (s.plugin(), s.source()) != (TESTER_PLUGIN_NAME, TESTER_SOURCE_NAME));

            let mut expected_sources = self.sources;
            actual_sources.sort_by_key(|n| (n.plugin().to_owned(), n.source().to_owned()));
            expected_sources.sort_by_key(|n| (n.plugin().to_owned(), n.source().to_owned()));
            assert_eq!(
                actual_sources, expected_sources,
                "registered sources do not match what you requested"
            );

            let mut actual_transforms = pipeline.inspect().transforms();
            let mut expected_transforms = self.transforms;
            actual_transforms.sort_by_key(|n| (n.plugin().to_owned(), n.transform().to_owned()));
            expected_transforms.sort_by_key(|n| (n.plugin().to_owned(), n.transform().to_owned()));
            assert_eq!(
                actual_transforms, expected_transforms,
                "registered transforms do not match what you requested"
            );

            let mut actual_outputs = pipeline.inspect().outputs();
            let mut expected_outputs = self.outputs;
            actual_outputs.sort_by_key(|n| (n.plugin().to_owned(), n.output().to_owned()));
            expected_outputs.sort_by_key(|n| (n.plugin().to_owned(), n.output().to_owned()));
            assert_eq!(
                actual_outputs, expected_outputs,
                "registered outputs do not match what you requested"
            );
        });

        builder
    }
}

impl StartupExpectations {
    pub fn new() -> Self {
        Self::default()
    }

    /// Requires the given metric to be registered before the measurement pipeline starts.
    pub fn expect_metric_untyped(mut self, metric: Metric) -> Self {
        self.metrics.push(metric);
        self
    }

    /// Requires the given metric to be registered before the measurement pipeline starts.
    pub fn expect_metric<T: MeasurementType>(mut self, name: &str, unit: impl Into<PrefixedUnit>) -> Self {
        self.metrics.push(Metric {
            name: name.into(),
            value_type: T::wrapped_type(),
            unit: unit.into(),
        });
        self
    }

    /// Requires a source to exist before the measurement pipeline starts.
    pub fn expect_source(mut self, plugin_name: &str, source_name: &str) -> Self {
        // TODO (maybe) take the source type into account (autonomous/managed)?
        self.sources
            .push(SourceName::new(plugin_name.to_owned(), source_name.to_owned()));
        self
    }

    /// Requires a transform to exist before the measurement pipeline starts.
    pub fn expect_transform(mut self, plugin_name: &str, transform_name: &str) -> Self {
        self.transforms
            .push(TransformName::new(plugin_name.to_owned(), transform_name.to_owned()));
        self
    }

    /// Requires an output to exist before the measurement pipeline starts.
    pub fn expect_output(mut self, plugin_name: &str, output_name: &str) -> Self {
        self.outputs
            .push(OutputName::new(plugin_name.to_owned(), output_name.to_owned()));
        self
    }
}
