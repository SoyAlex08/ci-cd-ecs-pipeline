import os

import pymysql
from flask import Flask, jsonify

app = Flask(__name__)


def get_connection():
    return pymysql.connect(
        host=os.environ["DB_HOST"],
        user=os.environ["DB_USER"],
        password=os.environ["DB_PASSWORD"],
        database=os.environ["DB_NAME"],
        connect_timeout=5,
    )


@app.route("/health")
def health():
    # Health check del ALB: solo confirma que el proceso Flask esta vivo,
    # sin depender de la base de datos (evita marcar la tarea unhealthy
    # por una lentitud puntual de RDS).
    return jsonify(status="ok"), 200


@app.route("/")
def index():
    try:
        conn = get_connection()
        with conn.cursor() as cur:
            cur.execute("SELECT VERSION();")
            version = cur.fetchone()[0]
        conn.close()
        return f"""
        <h1>Plataforma de e-commerce - implementacion funcional</h1>
        <p>Conexion a la base de datos gestionada (RDS MySQL): <strong>exitosa</strong></p>
        <p>Version del motor: {version}</p>
        <p>Servido desde ECS Fargate detras del Application Load Balancer.</p>
        """
    except Exception as exc:
        return f"""
        <h1>Plataforma de e-commerce - implementacion funcional</h1>
        <p>Conexion a la base de datos: <strong>fallo</strong></p>
        <p>{exc}</p>
        """, 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
