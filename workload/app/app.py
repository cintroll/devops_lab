from flask import Flask
from prometheus_flask_exporter import PrometheusMetrics

def create_app():
    app = Flask(__name__)
    PrometheusMetrics(app)

    @app.route("/")
    def hello_world():
        return "<p>Hello, World!</p>"

    return app

if __name__ == "__main__":
    app = create_app()

    app.run(debug=True)